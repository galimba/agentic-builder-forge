#!/usr/bin/env bash
# ==============================================================================
# FORGE DOCTOR — structural diagnostics for the build-harness.
#
#   bash .forge/scripts/doctor.sh              # at-rest OR initialized: structure checks
#   bash .forge/scripts/doctor.sh --post-init  # strict: proves init completed correctly
#   bash .forge/scripts/doctor.sh --gate       # also run the canonical test gate
#
# At rest (fresh clone, before init) placeholders are EXPECTED and the ledger is
# absent — that is healthy. --post-init makes those hard failures instead.
# ==============================================================================
set -u

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POST_INIT=0
RUN_GATE=0
for arg in "$@"; do
    case "$arg" in
        --post-init) POST_INIT=1 ;;
        --gate) RUN_GATE=1 ;;
        *) echo "usage: doctor.sh [--post-init] [--gate]"; exit 2 ;;
    esac
done

PASS=0; FAIL=0; INFO=0
ok()   { PASS=$((PASS+1)); printf '  OK   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
info() { INFO=$((INFO+1)); printf '  --   %s\n' "$1"; }

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
echo "== doctor: ${PASS} ok, ${FAIL} failed, ${INFO} informational =="
[[ "$FAIL" -eq 0 ]]
