#!/usr/bin/env bash
# ==============================================================================
# FORGE INITIALIZATION SCRIPT
# ==============================================================================
# Run this after cloning the template to configure the build-harness for your
# organization. Idempotent: re-running is guarded and safe.
#
#   bash .forge/scripts/init.sh
#
# Run this from YOUR shell, as the human operator. The harness's own enforcement
# floor (.claude/hooks/*) governs agent sessions, not this script — but because
# the values collected here are substituted into enforcement-adjacent files,
# every input is validated and escaped before use.
# ==============================================================================

set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ==============================================================================
# NON-INTERACTIVE MODE (Phase 5a): flags/env for headless/CI init. Every resolved
# value still flows through the SAME validate_input/validate_token/escape gates
# below — a flag/env value NEVER bypasses validation. All enforce-adjacent writes
# stay internal to this bash process (the deny hook is subprocess-blind); they are
# never driven through agent Write/Edit tool calls.
# ==============================================================================
NONINTERACTIVE="${FORGE_INIT_NONINTERACTIVE:-0}"
usage() {
    cat <<'EOF'
Usage: bash .forge/scripts/init.sh [--non-interactive] [--reinit] [--help]

Interactive by default. In --non-interactive mode (or FORGE_INIT_NONINTERACTIVE=1),
every value is read from an env var; a required value with no default aborts (exit 2):

  FORGE_INIT_REPO_NAME        (required)  repository name (lowercase, URL-safe)
  FORGE_INIT_ORG_NAME         (required)  organization display name
  FORGE_INIT_GITHUB_ORG       (required)  github org or username
  FORGE_INIT_MAINTAINER       (required)  CODEOWNERS maintainer (user or @team)
  FORGE_INIT_PLATFORM         (default: claude-code)
  FORGE_INIT_DEFAULT_BRANCH   (default: main)
  FORGE_INIT_BEAD_PREFIX      (default: fx)
  FORGE_INIT_GIT_AUTHOR_NAME  (default: "<repo> harness")
  FORGE_INIT_GIT_AUTHOR_EMAIL (default: forge-harness@localhost)
  FORGE_INIT_REVIEWER_BACKEND (default: auto-detected ollama/claude-fresh)
  FORGE_INIT_TARGET_BRANCH_NS (default: forge/agent)
  FORGE_INIT_SANDBOX_NETWORK  (default: bridge)  env-only knob — see the note init prints
  FORGE_INIT_TARGET_CONTAINER (default: 1)        env-only knob — see the note init prints
  FORGE_INIT_SENTINEL_NS      (default: forge)
  FORGE_INIT_REINIT=y | --reinit   proceed past the already-initialized guard
  FORGE_INIT_UPDATE_REMOTE (default: y)  FORGE_INIT_SCAFFOLD (default: y)  FORGE_INIT_RUN_DOCTOR (default: y)
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --non-interactive | -y | --yes) NONINTERACTIVE=1 ;;
        --reinit) FORGE_INIT_REINIT=y ;;
        -h | --help) usage; exit 0 ;;
        *) echo "init: unknown argument '$1' (see --help)"; exit 2 ;;
    esac
    shift
done

# ask <VAR> <ENV> <DEFAULT> <PROMPT> — resolve one value: env var in non-interactive mode, read -rp
# otherwise. A REQUIRED value passes an EMPTY default; a missing required value in non-interactive mode
# aborts naming the env var. The resolved value is validated by the SAME gates below (never bypassed).
ask() {
    local __var="$1" __env="$2" __def="$3" __prompt="$4" __val
    if [ "$NONINTERACTIVE" = "1" ]; then
        __val="${!__env-}"; [ -n "$__val" ] || __val="$__def"
        [ -n "$__val" ] || { echo "ERROR: non-interactive init requires ${__env} (no default for ${__var})."; exit 2; }
    else
        read -rp "$__prompt" __val; [ -n "$__val" ] || __val="$__def"
    fi
    printf -v "$__var" '%s' "$__val"
}
# confirm <ENV> <default y|n> <PROMPT> — a y/N gate; env var in non-interactive mode.
confirm() {
    local __env="$1" __def="$2" __prompt="$3" __ans
    if [ "$NONINTERACTIVE" = "1" ]; then __ans="${!__env:-$__def}"; else read -rp "$__prompt" __ans; __ans="${__ans:-$__def}"; fi
    case "$__ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
# ctx — print prompt-context banner lines only in interactive mode.
ctx() { [ "$NONINTERACTIVE" = "1" ] || printf '%s\n' "$@"; }

# ==============================================================================
# IDEMPOTENCY: warn if this instance has already been initialized.
# ==============================================================================
if [[ -f "${FORGE_ROOT}/.forge/.initialized" ]]; then
    echo ""
    echo "WARNING: this forge has already been initialized."
    echo ""
    cat "${FORGE_ROOT}/.forge/.initialized"
    echo ""
    if ! confirm FORGE_INIT_REINIT "N" "Re-run init? Placeholders already substituted will not change. Scaffolding steps will re-run. [y/N]: "; then
        echo "Aborted."
        exit 0
    fi
fi

# ==============================================================================
# SECURITY: escape user input for safe use in sed replacement strings.
# sed treats /, &, \, and newlines as special in the replacement part of s///.
# ==============================================================================
escape_sed_replacement() {
    local input="$1"
    input="${input//\\/\\\\}"   # \ -> \\
    input="${input//\//\\/}"    # / -> \/
    input="${input//&/\\&}"     # & -> \&
    input="${input//$'\n'/}"    # strip newlines — they break sed and never belong in names
    printf '%s' "$input"
}

# ==============================================================================
# SECURITY: validate user input does not contain shell metacharacters that
# could cause command injection when interpolated into sed expressions.
# Rejects: $(...), backticks, and control characters (except tab).
# ==============================================================================
validate_input() {
    local name="$1" value="$2"
    if [[ "$value" == *'$('* ]] || [[ "$value" == *'`'* ]]; then
        echo "ERROR: ${name} contains forbidden characters (\$(...) or backticks)."
        exit 2
    fi
    local stripped="${value//$'\t'/}"
    if [[ "$stripped" =~ [[:cntrl:]] ]]; then
        echo "ERROR: ${name} contains control characters."
        exit 2
    fi
}

# Strict token validator for values that land inside code/config (not just docs).
validate_token() {
    local name="$1" value="$2" pattern="$3" hint="$4"
    if [[ ! "$value" =~ $pattern ]]; then
        echo "ERROR: ${name} '${value}' is invalid — ${hint}"
        exit 2
    fi
}

echo ""
echo "================================================"
echo "  AGENTIC BUILDER FORGE — Initialization"
echo "================================================"
echo ""

# ---- detect environment defaults --------------------------------------------
BD_DETECTED="$(command -v bd 2>/dev/null || true)"
if command -v claude >/dev/null 2>&1; then
    REVIEWER_DEFAULT="claude-fresh"
    REVIEWER_WHY="a Claude Code environment was detected"
elif command -v ollama >/dev/null 2>&1; then
    REVIEWER_DEFAULT="ollama"
    REVIEWER_WHY="ollama was detected (local, no API tokens)"
else
    REVIEWER_DEFAULT="ollama"
    REVIEWER_WHY="no backend CLI detected; ollama is the locally-runnable default (install + pull a model before first review)"
fi

# ---- gather configuration ----------------------------------------------------
ask REPO_NAME        FORGE_INIT_REPO_NAME        ""                        "Repository name (e.g., acme-forge): "
ask ORG_NAME         FORGE_INIT_ORG_NAME         ""                        "Organization name (e.g., Acme Corp): "
ask GITHUB_ORG       FORGE_INIT_GITHUB_ORG       ""                        "GitHub org or username (e.g., acme-corp): "
ask MAINTAINER       FORGE_INIT_MAINTAINER       ""                        "GitHub maintainer user or team for CODEOWNERS (e.g., my-team): "
ask PLATFORM         FORGE_INIT_PLATFORM         "claude-code"             "Primary agent platform [claude-code/codex/custom] (default: claude-code): "
ask DEFAULT_BRANCH   FORGE_INIT_DEFAULT_BRANCH   "main"                    "Default branch (default: main): "
ask BEAD_PREFIX      FORGE_INIT_BEAD_PREFIX      "fx"                      "Task-ledger ID prefix — short, lowercase (default: fx): "
ask GIT_AUTHOR_NAME  FORGE_INIT_GIT_AUTHOR_NAME  "${REPO_NAME} harness"    "Harness git author name for automated commits (default: ${REPO_NAME} harness): "
ask GIT_AUTHOR_EMAIL FORGE_INIT_GIT_AUTHOR_EMAIL "forge-harness@localhost" "Harness git author email (default: forge-harness@localhost): "
ctx "" "Reviewer backend default: ${REVIEWER_DEFAULT} (${REVIEWER_WHY})"
ask REVIEWER_BACKEND FORGE_INIT_REVIEWER_BACKEND "${REVIEWER_DEFAULT}"     "Reviewer backend [ollama/claude-fresh/codex] (default: ${REVIEWER_DEFAULT}): "
ctx "" \
    "Target-repo agent branches are named '<namespace>/builder/<id>-<slug>' (self builds keep" \
    "'task/<id>-<slug>'). The reconcile close binds to this namespace; the default is fine for almost" \
    "everyone."
ask FORGE_TARGET_BRANCH_NS FORGE_INIT_TARGET_BRANCH_NS "forge/agent"       "Target-repo branch namespace (default: forge/agent): "
case "$FORGE_TARGET_BRANCH_NS" in
  '' | *[!A-Za-z0-9/_-]* | /* | */ | task | task/*)
    echo "ERROR: invalid branch namespace '${FORGE_TARGET_BRANCH_NS}'. Use [A-Za-z0-9/_-], no leading/trailing slash, not 'task'."; exit 2 ;;
esac
ctx "" \
    "Container topology (Phase 2). Target-repo builds run in a networked isolation container by default." \
    "These are ENV-ONLY knobs (read at runtime with these defaults); init records your choice and prints" \
    "how to make a non-default value stick — it does not persist them to a config file."
ask FORGE_SANDBOX_NETWORK FORGE_INIT_SANDBOX_NETWORK "bridge"              "Container network [bridge/none] (default: bridge = networked; 'none' restores egress-deny): "
case "$FORGE_SANDBOX_NETWORK" in
  bridge | none | host) ;;
  *) echo "ERROR: invalid FORGE_SANDBOX_NETWORK '${FORGE_SANDBOX_NETWORK}'. Use bridge (networked), none (egress-deny), or host."; exit 2 ;;
esac
ask FORGE_TARGET_CONTAINER FORGE_INIT_TARGET_CONTAINER "1"                 "Container-default for target builds? [1/0] (default: 1 = on; 0 = host-side): "
case "$FORGE_TARGET_CONTAINER" in
  0 | 1) ;;
  *) echo "ERROR: invalid FORGE_TARGET_CONTAINER '${FORGE_TARGET_CONTAINER}'. Use 1 (container-default) or 0 (host-side)."; exit 2 ;;
esac
ctx "" \
    "The harness marks and parses structured blocks with an internal marker" \
    "namespace (e.g. '<!-- forge:tasks:begin v1 -->'). The default is fine for" \
    "almost everyone; override only if 'forge:' collides with your tooling."
ask SENTINEL_NS      FORGE_INIT_SENTINEL_NS      "forge"                   "Marker namespace (default: forge): "
INIT_DATE=$(date +%Y-%m-%d)

# normalize
MAINTAINER="${MAINTAINER#@}"

# ---- validate ----------------------------------------------------------------
validate_input "REPO_NAME" "$REPO_NAME"
validate_input "ORG_NAME" "$ORG_NAME"
validate_input "GITHUB_ORG" "$GITHUB_ORG"
validate_input "MAINTAINER" "$MAINTAINER"
validate_input "PLATFORM" "$PLATFORM"
validate_input "GIT_AUTHOR_NAME" "$GIT_AUTHOR_NAME"
validate_input "GIT_AUTHOR_EMAIL" "$GIT_AUTHOR_EMAIL"
validate_token "REPO_NAME" "$REPO_NAME" '^[a-z0-9][a-z0-9._-]{0,63}$' "use lowercase letters, digits, ., _, - (it becomes the package name and URL segment)"
validate_token "DEFAULT_BRANCH" "$DEFAULT_BRANCH" '^[A-Za-z0-9][A-Za-z0-9._/-]{0,100}$' "must be a valid git branch name"
# The MECHANICAL protected-branch guard (deny hook + commit githook) covers `main` and `master`
# by name. A different default is protected by convention + GitHub branch protection, not the local
# guard — warn so nobody assumes a mechanical guarantee that isn't there.
case "$DEFAULT_BRANCH" in
    main|master) ;;
    *) echo "  NOTE: the mechanical commit/push guard protects 'main' and 'master' by name."
       echo "        '${DEFAULT_BRANCH}' will rely on GitHub branch protection + convention, not the local guard." ;;
esac
validate_token "BEAD_PREFIX" "$BEAD_PREFIX" '^[a-z][a-z0-9]{0,9}$' "short lowercase alphanumeric, starting with a letter (task IDs look like <prefix>-a1b2)"
validate_token "SENTINEL_NS" "$SENTINEL_NS" '^[a-z][a-z0-9]{1,15}$' "lowercase alphanumeric, 2-16 chars"
case "$REVIEWER_BACKEND" in
    ollama|claude-fresh|codex) ;;
    *) echo "ERROR: invalid reviewer backend '${REVIEWER_BACKEND}'. Must be ollama, claude-fresh, or codex."; exit 2 ;;
esac
case "$PLATFORM" in
    claude-code|codex|custom) ;;
    *) echo "ERROR: invalid platform '${PLATFORM}'. Must be claude-code, codex, or custom."; exit 2 ;;
esac

# escape for sed
REPO_NAME_SED=$(escape_sed_replacement "$REPO_NAME")
ORG_NAME_SED=$(escape_sed_replacement "$ORG_NAME")
GITHUB_ORG_SED=$(escape_sed_replacement "$GITHUB_ORG")
MAINTAINER_SED=$(escape_sed_replacement "$MAINTAINER")
PLATFORM_SED=$(escape_sed_replacement "$PLATFORM")
DEFAULT_BRANCH_SED=$(escape_sed_replacement "$DEFAULT_BRANCH")
BEAD_PREFIX_SED=$(escape_sed_replacement "$BEAD_PREFIX")
GIT_AUTHOR_NAME_SED=$(escape_sed_replacement "$GIT_AUTHOR_NAME")
GIT_AUTHOR_EMAIL_SED=$(escape_sed_replacement "$GIT_AUTHOR_EMAIL")
INIT_DATE_SED=$(escape_sed_replacement "$INIT_DATE")

echo ""
echo "Configuring forge: ${REPO_NAME}"
echo "Organization:      ${ORG_NAME}"
echo "GitHub:            ${GITHUB_ORG}"
echo "Maintainer:        @${MAINTAINER}"
echo "Platform:          ${PLATFORM}"
echo "Default branch:    ${DEFAULT_BRANCH}"
echo "Ledger prefix:     ${BEAD_PREFIX}"
echo "Harness author:    ${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>"
echo "Reviewer backend:  ${REVIEWER_BACKEND}"
echo "Marker namespace:  ${SENTINEL_NS}:"
echo "Date:              ${INIT_DATE}"
echo ""

# ==============================================================================
# 1. PLACEHOLDER SUBSTITUTION — markdown + GitHub config
# ==============================================================================
echo "Replacing placeholders in markdown files..."
find "${FORGE_ROOT}" -maxdepth 10 -name "*.md" \
    -not -path "${FORGE_ROOT}/.git/*" -not -path "${FORGE_ROOT}/node_modules/*" \
    ! -type l -type f -exec sed -i \
    -e "s/{{REPO_NAME}}/${REPO_NAME_SED}/g" \
    -e "s/{{ORG_NAME}}/${ORG_NAME_SED}/g" \
    -e "s/{{GITHUB_ORG}}/${GITHUB_ORG_SED}/g" \
    -e "s/{{MAINTAINER}}/${MAINTAINER_SED}/g" \
    -e "s/{{PLATFORM}}/${PLATFORM_SED}/g" \
    -e "s/{{DEFAULT_BRANCH}}/${DEFAULT_BRANCH_SED}/g" \
    -e "s/{{BEAD_PREFIX}}/${BEAD_PREFIX_SED}/g" \
    -e "s/{{GIT_AUTHOR_NAME}}/${GIT_AUTHOR_NAME_SED}/g" \
    -e "s/{{GIT_AUTHOR_EMAIL}}/${GIT_AUTHOR_EMAIL_SED}/g" \
    -e "s/{{INIT_DATE}}/${INIT_DATE_SED}/g" \
    {} +
echo "  Done"

echo "Replacing placeholders in .github/ config..."
if [[ -d "${FORGE_ROOT}/.github" ]]; then
    find "${FORGE_ROOT}/.github" -maxdepth 5 \( -name "*.yml" -o -name "*.yaml" \) ! -type l -type f -exec sed -i \
        -e "s/{{GITHUB_ORG}}/${GITHUB_ORG_SED}/g" \
        -e "s/{{REPO_NAME}}/${REPO_NAME_SED}/g" \
        -e "s/{{MAINTAINER}}/${MAINTAINER_SED}/g" \
        {} +
    if [[ -f "${FORGE_ROOT}/.github/CODEOWNERS" ]]; then
        sed -i \
            -e "s/{{GITHUB_ORG}}/${GITHUB_ORG_SED}/g" \
            -e "s/{{REPO_NAME}}/${REPO_NAME_SED}/g" \
            -e "s/{{MAINTAINER}}/${MAINTAINER_SED}/g" \
            "${FORGE_ROOT}/.github/CODEOWNERS"
    fi
fi
echo "  Done"

# ==============================================================================
# 2. PACKAGE IDENTITY
# ==============================================================================
echo "Setting package identity..."
if command -v jq >/dev/null 2>&1; then
    jq --arg n "$REPO_NAME" --arg d "Deterministic agentic build-harness for ${ORG_NAME}. Human-supervised." \
        '.name = $n | .description = $d' \
        "${FORGE_ROOT}/package.json" > "${FORGE_ROOT}/package.json.tmp"
    mv "${FORGE_ROOT}/package.json.tmp" "${FORGE_ROOT}/package.json"
    echo "  package.json name/description set"
else
    echo "  WARNING: jq not found — edit package.json name/description manually."
    echo "           (jq is REQUIRED by the harness itself; install it before first use.)"
fi

# ==============================================================================
# 3. BEADS (task ledger) CONFIG — identity is GENERATED, never copied
# ==============================================================================
echo "Configuring the task ledger (beads)..."
if [[ -n "$BD_DETECTED" ]]; then
    sed -i "s|^BD_BIN=.*$|BD_BIN=\"\${BD_BIN:-${BD_DETECTED}}\"   # absolute path pinned by init — the gate pins PATH + unsets BD_BIN|" \
        "${FORGE_ROOT}/harness/beads.config"
    echo "  BD_BIN -> ${BD_DETECTED} (absolute, pinned)"
else
    echo "  WARNING: 'bd' (beads) not found on PATH. Install it, then set BD_BIN in"
    echo "           harness/beads.config to its ABSOLUTE path (the gate pins PATH,"
    echo "           so a bare 'bd' would not resolve)."
fi
sed -i \
    -e "s/^BD_PREFIX=\"[a-z0-9]*\"/BD_PREFIX=\"${BEAD_PREFIX_SED}\"/" \
    -e "s/bd init -p [a-z0-9]*/bd init -p ${BEAD_PREFIX_SED}/g" \
    -e "s/ids look like [a-z0-9]*-<hash>/ids look like ${BEAD_PREFIX_SED}-<hash>/" \
    "${FORGE_ROOT}/harness/beads.config"
echo "  BD_PREFIX -> ${BEAD_PREFIX}"

# ==============================================================================
# 4. HARNESS GIT IDENTITY (sandbox-lib.sh commits as the harness, by design:
#    it reads NO git config at runtime, so the identity must be substituted here)
# ==============================================================================
echo "Setting harness git identity..."
perl -pi -e '
    BEGIN { $an = shift @ARGV; $ae = shift @ARGV; }
    s/an="[^"]*"; ae="[^"]*"/an="$an"; ae="$ae"/;
    s/GIT_AUTHOR_NAME="[^"]*" GIT_AUTHOR_EMAIL="[^"]*"/GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae"/;
    s/GIT_COMMITTER_NAME="[^"]*" GIT_COMMITTER_EMAIL="[^"]*"/GIT_COMMITTER_NAME="$an" GIT_COMMITTER_EMAIL="$ae"/;
' "$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL" "${FORGE_ROOT}/harness/sandbox-lib.sh"
echo "  Automated commits will be authored as: ${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>"

# ==============================================================================
# 5. REVIEWER BACKEND
# ==============================================================================
echo "Setting reviewer backend default..."
sed -i "s/^REVIEWER_BACKEND=\"\${REVIEWER_BACKEND:-[a-z-]*}\"/REVIEWER_BACKEND=\"\${REVIEWER_BACKEND:-${REVIEWER_BACKEND}}\"/" \
    "${FORGE_ROOT}/harness/reviewers.config"
echo "  REVIEWER_BACKEND default -> ${REVIEWER_BACKEND} (env override still wins)"
if [[ "$REVIEWER_BACKEND" == "ollama" ]]; then
    echo "  NOTE: set ollama_MODEL in harness/reviewers.config to a model you have pulled."
fi

# Target-repo branch namespace (Phase 3). Enforce-protected + trusted by the reconcile close.
echo "Setting target-repo branch namespace..."
sed -i "s|^FORGE_TARGET_BRANCH_NS=.*|FORGE_TARGET_BRANCH_NS=\"${FORGE_TARGET_BRANCH_NS}\"|" \
    "${FORGE_ROOT}/harness/branches.config"
echo "  FORGE_TARGET_BRANCH_NS -> ${FORGE_TARGET_BRANCH_NS} (target-repo builder branches: ${FORGE_TARGET_BRANCH_NS}/builder/<id>-<slug>; self builds keep task/<id>-<slug>)"

# Container topology knobs (Phase 2) — ENV-ONLY. Runtime reads them with defaults (bridge / on); init does
# NOT persist them to a config, so a NON-DEFAULT choice must be exported in the shell/CI environment that
# runs the harness. Guidance only (the defaults need no action).
echo "Container topology (env-only knobs; defaults need no action):"
if [ "${FORGE_SANDBOX_NETWORK}" != "bridge" ] || [ "${FORGE_TARGET_CONTAINER}" != "1" ]; then
    echo "  NON-DEFAULT chosen — export these where the harness runs (shell profile / CI env), e.g.:"
    [ "${FORGE_SANDBOX_NETWORK}" != "bridge" ] && echo "      export FORGE_SANDBOX_NETWORK=${FORGE_SANDBOX_NETWORK}"
    [ "${FORGE_TARGET_CONTAINER}" != "1" ]     && echo "      export FORGE_TARGET_CONTAINER=${FORGE_TARGET_CONTAINER}"
    echo "  (they are read at runtime by harness/sandbox-lib.sh + harness/run-task.sh, not persisted here.)"
else
    echo "  FORGE_SANDBOX_NETWORK=bridge (networked), FORGE_TARGET_CONTAINER=1 (container-default) — defaults, no action needed."
fi

# ==============================================================================
# 6. MARKER NAMESPACE (optional rename — must stay consistent EVERYWHERE it is
#    both emitted and parsed: harness scripts, agent/skill docs, templates, tests)
# ==============================================================================
if [[ "$SENTINEL_NS" != "forge" ]]; then
    echo "Renaming marker namespace forge: -> ${SENTINEL_NS}: ..."
    before_count="$(grep -rEo 'forge:(tasks|spec-review|review|disposition)' "${FORGE_ROOT}" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.forge 2>/dev/null | wc -l)"
    grep -rlE 'forge:(tasks|spec-review|review|disposition)' "${FORGE_ROOT}" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.forge 2>/dev/null \
        | while IFS= read -r f; do
            perl -pi -e "s/\bforge:(tasks|spec-review|review|disposition)\b/${SENTINEL_NS}:\$1/g" "$f"
        done
    after_count="$(grep -rEo "${SENTINEL_NS}:(tasks|spec-review|review|disposition)" "${FORGE_ROOT}" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.forge 2>/dev/null | wc -l)"
    if [[ "$before_count" != "$after_count" ]]; then
        echo "  ERROR: marker rename count mismatch (before=${before_count} after=${after_count})."
        echo "         The namespace must be consistent everywhere; re-clone and retry."
        exit 2
    fi
    echo "  Renamed ${after_count} marker occurrences; emitters and parsers stay in lockstep."
else
    echo "Marker namespace: keeping default 'forge:'"
fi

# ==============================================================================
# 7. TARGET REPO MAP
# ==============================================================================
if [[ ! -f "${FORGE_ROOT}/harness/repos.config" ]]; then
    cp "${FORGE_ROOT}/harness/repos.config.example" "${FORGE_ROOT}/harness/repos.config"
    echo "harness/repos.config created from the example — fill in your target repos"
    echo "  (absolute local clone paths; the file is gitignored because paths are host-specific)."
fi

# ==============================================================================
# 8. GIT WIRING
# ==============================================================================
echo ""
echo "Wiring git..."
# A source download (tarball/zip) has no .git — initialize one so the guards can wire.
if [[ ! -d "${FORGE_ROOT}/.git" ]]; then
    git -C "${FORGE_ROOT}" init -q
    git -C "${FORGE_ROOT}" symbolic-ref HEAD "refs/heads/${DEFAULT_BRANCH}" 2>/dev/null || true
    echo "  git repository initialized (no .git was present)"
fi
# The SessionStart witness REFUSES to witness a session whose hooks path is not
# harness/githooks — this is required, not optional.
git -C "${FORGE_ROOT}" config core.hooksPath harness/githooks
echo "  core.hooksPath -> harness/githooks (required by the session witness)"
git -C "${FORGE_ROOT}" config beads.role maintainer 2>/dev/null || true

CURRENT_REMOTE=$(git -C "${FORGE_ROOT}" remote get-url origin 2>/dev/null || true)
if [[ -n "$CURRENT_REMOTE" ]] && [[ "$CURRENT_REMOTE" == *"agentic-builder-forge"* ]]; then
    NEW_REMOTE="https://github.com/${GITHUB_ORG}/${REPO_NAME}.git"
    echo "Current git remote points to the template repository."
    echo "  Current:   ${CURRENT_REMOTE}"
    echo "  Suggested: ${NEW_REMOTE}"
    if confirm FORGE_INIT_UPDATE_REMOTE "Y" "Update remote origin? [Y/n]: "; then
        git -C "${FORGE_ROOT}" remote set-url origin "${NEW_REMOTE}"
        echo "  Remote updated"
    else
        echo "  Skipped. Update manually: git remote set-url origin <your-url>"
    fi
fi

# ==============================================================================
# 9. FRESH TASK LEDGER — generated, NEVER copied. A ledger carries a project
#    identity (UUID) and task history; two instances must never share either.
# ==============================================================================
echo ""
echo "Creating a fresh, empty task ledger..."
if [[ -d "${FORGE_ROOT}/.beads" ]]; then
    echo "  .beads/ already exists — leaving it untouched (delete it and re-run init"
    echo "  if you meant to start over; NEVER copy a ledger between instances)."
elif [[ -n "$BD_DETECTED" ]]; then
    (
        cd "${FORGE_ROOT}"
        "$BD_DETECTED" init --skip-agents --skip-hooks --non-interactive -p "$BEAD_PREFIX"
        "$BD_DETECTED" config set status.custom "in_review:wip"
    )
    LEDGER="$(cd "${FORGE_ROOT}" && "$BD_DETECTED" list --json 2>/dev/null || echo '[]')"
    if [[ "$(printf '%s' "$LEDGER" | tr -d '[:space:]')" == "[]" ]]; then
        echo "  Fresh ledger created: prefix '${BEAD_PREFIX}', empty, with its own new project identity."
    else
        echo "  WARNING: the new ledger is not empty — inspect .beads/ before using the harness."
    fi
else
    echo "  'bd' not found — after installing beads, run:"
    echo "      bd init --skip-agents --skip-hooks --non-interactive -p ${BEAD_PREFIX}"
    echo "      bd config set status.custom \"in_review:wip\""
fi

# ==============================================================================
# 10. ENFORCEMENT FLOOR — nothing to configure, on purpose.
# ==============================================================================
echo ""
echo "Enforcement floor: the integrity baseline SELF-MINTS at your first agent"
echo "session (SessionStart witnesses the deployed hooks and pins their hash for"
echo "that session). There is NO committed floor hash to copy — do not create one."

# ==============================================================================
# 11. INSTANCE SCAFFOLDING — turn template docs into your instance docs
# ==============================================================================
echo ""
echo "================================================"
echo "  Instance Scaffolding"
echo "================================================"
echo ""
echo "The current README.md documents the TEMPLATE. I can reorganize for your instance:"
echo ""
echo "  README.md                      -> rewritten as your team's harness gateway"
echo "  docs/forge-template-readme.md  -> template docs (preserved)"
echo "  docs/onboarding.md             -> starter onboarding guide"
echo "  CHANGELOG.md                   -> fresh changelog"
echo ""
if confirm FORGE_INIT_SCAFFOLD "Y" "Proceed? [Y/n]: "; then
    if [[ -f "${FORGE_ROOT}/templates/readme-instance.md" ]]; then
        {
            echo "> This file contains the original template documentation."
            echo "> Upstream template: https://github.com/galimba/agentic-builder-forge"
            echo ""
            cat "${FORGE_ROOT}/README.md"
        } > "${FORGE_ROOT}/docs/forge-template-readme.md"
        cp "${FORGE_ROOT}/templates/readme-instance.md" "${FORGE_ROOT}/README.md"
        echo "  README.md replaced with instance gateway"
    else
        echo "  WARNING: templates/readme-instance.md not found, skipping README replacement"
    fi

    if [[ -f "${FORGE_ROOT}/templates/onboarding-instance.md" ]]; then
        cp "${FORGE_ROOT}/templates/onboarding-instance.md" "${FORGE_ROOT}/docs/onboarding.md"
        echo "  docs/onboarding.md generated"
    fi

    cat > "${FORGE_ROOT}/CHANGELOG.md" <<CHANGELOG_EOF
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - ${INIT_DATE}

### Added

- Initialized build-harness from [agentic-builder-forge](https://github.com/galimba/agentic-builder-forge) template (v0.1.0)

[Unreleased]: https://github.com/${GITHUB_ORG}/${REPO_NAME}/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/${GITHUB_ORG}/${REPO_NAME}/releases/tag/v0.1.0
CHANGELOG_EOF
    echo "  CHANGELOG.md replaced with fresh instance changelog"
    echo ""
    echo "  Instance scaffolding complete"
else
    echo "  Skipped. You can reorganize files manually later."
fi

# ==============================================================================
# SAVE INITIALIZATION STATE
# ==============================================================================
mkdir -p "${FORGE_ROOT}/.forge"
cat > "${FORGE_ROOT}/.forge/.initialized" <<INIT_EOF
repo_name="${REPO_NAME}"
org_name="${ORG_NAME}"
github_org="${GITHUB_ORG}"
maintainer="${MAINTAINER}"
platform="${PLATFORM}"
default_branch="${DEFAULT_BRANCH}"
bead_prefix="${BEAD_PREFIX}"
git_author_name="${GIT_AUTHOR_NAME}"
git_author_email="${GIT_AUTHOR_EMAIL}"
reviewer_backend="${REVIEWER_BACKEND}"
target_branch_ns="${FORGE_TARGET_BRANCH_NS}"
sandbox_network="${FORGE_SANDBOX_NETWORK}"
target_container="${FORGE_TARGET_CONTAINER}"
sentinel_ns="${SENTINEL_NS}"
init_date="${INIT_DATE}"
template_version="0.1.0"
INIT_EOF
echo ""
echo "  State saved to .forge/.initialized (gitignored)"

# ==============================================================================
# POST-INIT CHECK
# ==============================================================================
echo ""
if confirm FORGE_INIT_RUN_DOCTOR "Y" "Run the post-init check (doctor)? [Y/n]: "; then
    echo ""
    bash "${FORGE_ROOT}/.forge/scripts/doctor.sh" --post-init || {
        echo ""
        echo "Doctor reported problems — fix them before first use."
        exit 1
    }
fi

echo ""
echo "================================================"
echo "  Initialization Complete!"
echo "================================================"
echo ""
echo "What's next:"
echo ""
echo "  1. Fill in harness/repos.config with your target repos (absolute paths)"
echo "  2. Provision your reviewer backend (${REVIEWER_BACKEND}):"
echo "       ollama       -> ollama pull <model>; set ollama_MODEL in harness/reviewers.config"
echo "       claude-fresh -> ensure 'claude' CLI is authenticated"
echo "       codex        -> ensure 'codex' CLI is authenticated"
echo "  3. Optional oversight board: BOARD_OWNER=${GITHUB_ORG} ./harness/board-bootstrap.sh ensure"
echo "  4. Run the gate: bash tests/run-all.sh"
echo "  5. Start your first intake: ./harness/intake.sh start \"<objective>\" --target <repo>"
echo "       then: clarify -> spec-review -> ratify -> decompose -> ratify-breakdown -> analyze -> convert"
echo "       (full pipeline in docs/lifecycle.md)"
echo ""
echo "Useful commands:"
echo "  bash .forge/scripts/doctor.sh          — diagnostics"
echo "  bash tests/run-all.sh                  — the canonical gate"
echo "  ./harness/run-task.sh ready            — see ready tasks"
echo ""
