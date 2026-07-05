#!/usr/bin/env bash
# ==============================================================================
# FORGE DOCTOR — structural diagnostics for the build-harness.
#
#   bash .forge/scripts/doctor.sh              # at-rest OR initialized: structure + dependency preflight
#   bash .forge/scripts/doctor.sh --post-init  # strict: proves init completed; bd/gh absence FAILs
#   bash .forge/scripts/doctor.sh --container  # container-proof: docker/devcontainer absence FAILs
#   bash .forge/scripts/doctor.sh --gate       # also run the canonical test gate
#
# At rest (fresh clone, before init) placeholders are EXPECTED, the ledger is
# absent, and bd/gh/docker may be missing — that is healthy (info/warn, never fail;
# the CI at-rest contract). --post-init makes placeholders/ledger AND missing bd/gh
# hard failures; --container additionally requires the container toolchain.
# ==============================================================================
set -u

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_INIT=0
RUN_GATE=0
REQUIRE_CONTAINER=0
for arg in "$@"; do
    case "$arg" in
        --post-init) POST_INIT=1 ;;
        --gate) RUN_GATE=1 ;;
        --container | --require-container) REQUIRE_CONTAINER=1 ;;
        *) echo "usage: doctor.sh [--post-init] [--gate] [--container]"; exit 2 ;;
    esac
done

PASS=0; FAIL=0; INFO=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  OK   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
info() { INFO=$((INFO+1)); printf '  --   %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  WARN %s\n' "$1"; }   # advisory — never fails the run

echo "== forge doctor =="

# ---- 1. initialization state -------------------------------------------------
if [[ -f "${FORGE_ROOT}/.forge/.initialized" ]]; then
    ok "initialized ($(grep -E '^repo_name=' "${FORGE_ROOT}/.forge/.initialized" | head -1))"
    INITIALIZED=1
else
    INITIALIZED=0
    if [[ "$POST_INIT" == 1 ]]; then
        bad ".forge/.initialized missing — init did not complete"
    else
        info "not initialized yet (expected for a fresh template clone; run .forge/scripts/init.sh)"
    fi
fi

# ---- 1b. dependency preflight (Phase 5b) -------------------------------------
# Proves RUNNABILITY, not just structure. Lifecycle-critical tools (bd, gh) FAIL under --post-init and are
# info at rest — a fresh template clone or CI runner may lack them, and the CI job runs bare doctor.sh on an
# uninitialized checkout (the at-rest contract). The JS toolchain + the selected reviewer backend WARN
# (environment-dependent, never fail). The container toolchain (docker/devcontainer) WARN/SKIPs unless
# --container (an explicit container-proof mode) is requested.
echo "== dependency preflight =="
have() { command -v "$1" >/dev/null 2>&1; }
# lifecycle-critical: FAIL under --post-init, info at rest.
for _pair in "bd|the task ledger (claim / close / reconcile)" "gh|the PR flow + close-on-merge reconcile"; do
    _bin="${_pair%%|*}"; _why="${_pair#*|}"
    if have "$_bin"; then ok "${_bin} present — ${_why}"
    elif [[ "$POST_INIT" == 1 ]]; then bad "${_bin} NOT found — required for ${_why}; install it before first use"
    else info "${_bin} not found — needed at runtime for ${_why} (ok on an uninitialized template)"
    fi
done
# JS toolchain + the always-needed basics: WARN (never fail — the lifecycle degrades, it does not vanish).
have git  || warn "git not found — the harness cannot operate without it"
have jq   || warn "jq not found — the deny hook + harness scripts fail closed without it"
have node || warn "node not found — the default 'typescript' target + the harness test suites need Node.js >= 18.18"
have pnpm || warn "pnpm not found — the default 'typescript' target uses pnpm"
# the SELECTED reviewer backend's CLI: WARN if absent (first review run is the earliest failure point).
_rb="$(sed -n 's/^REVIEWER_BACKEND="\${REVIEWER_BACKEND:-\([a-z-]*\)}".*/\1/p' "${FORGE_ROOT}/harness/reviewers.config" 2>/dev/null | head -1)"
case "$_rb" in
    claude-fresh) have claude || warn "reviewer backend 'claude-fresh' selected but 'claude' is not on PATH" ;;
    ollama)       have ollama || warn "reviewer backend 'ollama' selected but 'ollama' is not on PATH (also pull a model)" ;;
    codex)        have codex  || warn "reviewer backend 'codex' selected but 'codex' is not on PATH" ;;
    "")           info "reviewer backend not resolvable from harness/reviewers.config (skipping backend probe)" ;;
esac
# container toolchain: WARN/SKIP unless --container (explicit container-proof mode makes it FAIL).
for _bin in docker devcontainer; do
    if have "$_bin"; then ok "${_bin} present — container builds available"
    elif [[ "$REQUIRE_CONTAINER" == 1 ]]; then bad "${_bin} NOT found — required in container-proof mode (--container)"
    else warn "${_bin} not found — needed only for container builds (FORGE_SANDBOX=1 / container-default targets); SKIP"
    fi
done

# ---- 2. residual placeholders -------------------------------------------------
# Tracked markdown + .github files must carry NO unfilled {{TOKENS}} after init.
PLACEHOLDER_HITS="$(grep -rEl '\{\{[A-Z_]+\}\}' "${FORGE_ROOT}" \
    --include='*.md' --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null | wc -l)"
GH_HITS=0
if [[ -d "${FORGE_ROOT}/.github" ]]; then
    GH_HITS="$(grep -rEl '\{\{[A-Z_]+\}\}' "${FORGE_ROOT}/.github" 2>/dev/null | wc -l)"
fi
TOTAL_HITS=$((PLACEHOLDER_HITS + GH_HITS))
if [[ "$TOTAL_HITS" -eq 0 ]]; then
    ok "no unfilled {{PLACEHOLDER}} tokens"
elif [[ "$POST_INIT" == 1 || "$INITIALIZED" == 1 ]]; then
    bad "${TOTAL_HITS} file(s) still carry unfilled {{PLACEHOLDER}} tokens (re-run init or fill manually):"
    grep -rEl '\{\{[A-Z_]+\}\}' "${FORGE_ROOT}" --include='*.md' --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null | sed "s|^${FORGE_ROOT}/|    |"
else
    info "${TOTAL_HITS} file(s) carry {{PLACEHOLDER}} tokens (expected at rest; init fills them)"
fi

# ---- 3. enforcement wiring -----------------------------------------------------
if [[ -f "${FORGE_ROOT}/.claude/settings.json" ]]; then
    ok ".claude/settings.json present"
else
    bad ".claude/settings.json missing — the enforcement floor is not wired"
fi
HOOKS_OK=1
for h in lib.sh pre-tool-use-deny.sh post-tool-use-format.sh stop-gate-tests.sh stop-gate-intake.sh pre-tool-use-clarify-gate.sh session-start-witness.sh; do
    if [[ ! -f "${FORGE_ROOT}/.claude/hooks/${h}" ]]; then
        bad ".claude/hooks/${h} missing"; HOOKS_OK=0
    elif ! bash -n "${FORGE_ROOT}/.claude/hooks/${h}" 2>/dev/null; then
        bad ".claude/hooks/${h} does not parse"; HOOKS_OK=0
    fi
done
[[ "$HOOKS_OK" == 1 ]] && ok "all 7 enforcement hooks present and parse"

# Floor baseline: SELF-MINTING by design. Assert no one has committed one.
if ls "${FORGE_ROOT}"/.harness/session-floor.*.json >/dev/null 2>&1 && \
   git -C "${FORGE_ROOT}" ls-files --error-unmatch .harness >/dev/null 2>&1; then
    bad ".harness/ session-floor records are TRACKED — floor baselines must never be committed"
else
    ok "floor baseline self-mints at SessionStart (none committed — correct)"
fi

# ---- 4. git hooks path ----------------------------------------------------------
HOOKS_PATH="$(git -C "${FORGE_ROOT}" config core.hooksPath 2>/dev/null || true)"
if [[ "$HOOKS_PATH" == "harness/githooks" ]]; then
    ok "core.hooksPath = harness/githooks (session witness requirement)"
elif [[ "$POST_INIT" == 1 || "$INITIALIZED" == 1 ]]; then
    bad "core.hooksPath is '${HOOKS_PATH:-unset}' — run: git config core.hooksPath harness/githooks"
else
    info "core.hooksPath not set yet (init sets it; the session witness requires it)"
fi

# ---- 5. marker namespace consistency --------------------------------------------
NS="$(grep -oE '<!-- [a-z0-9]+:tasks:begin' "${FORGE_ROOT}/harness/intake.sh" 2>/dev/null | head -1 | sed 's/<!-- //; s/:tasks:begin//')"
if [[ -z "$NS" ]]; then
    bad "cannot determine marker namespace from harness/intake.sh"
else
    STRAYS=0
    for surface in harness/accept-gate.sh harness/review-task.sh templates/spec-template.md \
                   .claude/agents/reviewer.md .claude/agents/disposition.md .claude/agents/spec-reviewer.md; do
        f="${FORGE_ROOT}/${surface}"
        [[ -f "$f" ]] || continue
        if grep -qE '(tasks|spec-review|review|disposition):begin' "$f" 2>/dev/null && \
           ! grep -qE "${NS}:(tasks|spec-review|review|disposition):begin" "$f" 2>/dev/null; then
            bad "marker namespace mismatch in ${surface} (expected '${NS}:')"
            STRAYS=1
        fi
    done
    [[ "$STRAYS" == 0 ]] && ok "marker namespace '${NS}:' consistent across emitters and parsers"
fi

# ---- 6. task ledger ---------------------------------------------------------------
BD_PREFIX_CFG="$(grep -E '^BD_PREFIX=' "${FORGE_ROOT}/harness/beads.config" 2>/dev/null | sed 's/^BD_PREFIX="//; s/".*//')"
BD_BIN_CFG="$(bash -c "source '${FORGE_ROOT}/harness/beads.config' 2>/dev/null && printf '%s' \"\$BD_BIN\"" 2>/dev/null || true)"
# a bare (non-absolute) BD_BIN is the at-rest template default — resolve it like beads-lib does
case "$BD_BIN_CFG" in
    /*) : ;;
    ?*) BD_BIN_CFG="$(command -v "$BD_BIN_CFG" 2>/dev/null || printf '%s' "$BD_BIN_CFG")" ;;
esac
if [[ -d "${FORGE_ROOT}/.beads" ]]; then
    if [[ -f "${FORGE_ROOT}/.beads/metadata.json" ]] && command -v jq >/dev/null 2>&1; then
        LEDGER_PREFIX="$(jq -r '.dolt_database // empty' "${FORGE_ROOT}/.beads/metadata.json" 2>/dev/null)"
        if [[ -n "$LEDGER_PREFIX" && "$LEDGER_PREFIX" != "$BD_PREFIX_CFG" ]]; then
            bad "ledger prefix '${LEDGER_PREFIX}' != beads.config BD_PREFIX '${BD_PREFIX_CFG}'"
        else
            ok "ledger present; prefix matches config ('${BD_PREFIX_CFG}')"
        fi
    else
        ok "ledger directory present"
    fi
    if [[ "$POST_INIT" == 1 ]]; then
        if [[ -n "$BD_BIN_CFG" && -x "$BD_BIN_CFG" ]]; then
            LEDGER_LIST="$(cd "${FORGE_ROOT}" && "$BD_BIN_CFG" list --json 2>/dev/null | tr -d '[:space:]')"
            if [[ "$LEDGER_LIST" == "[]" ]]; then
                ok "ledger is EMPTY and valid (a fresh instance starts with zero tasks)"
            else
                bad "ledger is not empty after init — a fresh instance must start empty (never copy a ledger)"
            fi
        else
            info "bd not runnable — cannot verify the ledger is empty (BD_BIN='${BD_BIN_CFG}')"
        fi
    fi
else
    if [[ "$POST_INIT" == 1 ]]; then
        if [[ -n "$BD_BIN_CFG" && -x "$BD_BIN_CFG" ]]; then
            bad ".beads/ missing after init — run: bd init --skip-agents --skip-hooks --non-interactive -p ${BD_PREFIX_CFG}"
        else
            info "ledger not created (bd not installed) — create it after installing beads"
        fi
    else
        info "no ledger yet (init creates a fresh one; NEVER copy .beads/ from another instance)"
    fi
fi
if [[ -n "$BD_BIN_CFG" && -x "$BD_BIN_CFG" ]]; then
    ok "BD_BIN resolves (${BD_BIN_CFG})"
else
    info "BD_BIN does not resolve ('${BD_BIN_CFG:-unset}') — the runner needs beads installed"
fi

# ---- 7. target repo map --------------------------------------------------------------
if [[ -f "${FORGE_ROOT}/harness/repos.config" ]]; then
    ok "harness/repos.config present (gitignored, host-specific)"
elif [[ "$POST_INIT" == 1 || "$INITIALIZED" == 1 ]]; then
    info "harness/repos.config missing — cp harness/repos.config.example and fill in targets"
else
    info "harness/repos.config not created yet (init copies the example)"
fi

# ---- 8. runtime state hygiene ----------------------------------------------------------
TRACKED_STATE="$(git -C "${FORGE_ROOT}" ls-files .harness .claude/worktrees harness/board.config harness/repos.config 2>/dev/null | head -5)"
if [[ -z "$TRACKED_STATE" ]]; then
    ok "no runtime/instance state is tracked (.harness/, worktrees, live configs all clean)"
else
    bad "instance/runtime state is TRACKED (must be gitignored): ${TRACKED_STATE}"
fi

# ---- optional: the canonical gate ---------------------------------------------------------
if [[ "$RUN_GATE" == 1 ]]; then
    echo ""
    echo "== running the canonical gate (tests/run-all.sh) =="
    if bash "${FORGE_ROOT}/tests/run-all.sh"; then
        ok "gate PASSED"
    else
        bad "gate FAILED"
    fi
fi

echo ""
echo "== doctor: ${PASS} ok, ${FAIL} failed, ${WARN} warn, ${INFO} informational =="
[[ "$FAIL" -eq 0 ]]
