#!/usr/bin/env bash
# agentic-builder-forge — PreToolUse deny hook.
#
# PRIMARY, bypass-surviving enforcement. Emits permissionDecision:"deny" — the documented
# form that blocks even under --dangerously-skip-permissions — with an exit-2 fail-closed
# fallback. permissions.deny in settings.json is only a REDUNDANT SECONDARY layer; this hook
# is the boundary.
#
# Tiers:
#   UNIVERSAL (always on): recursive rm outside sandbox/, force-push, push to main/master
#     (incl. refspec / --mirror / --all / on-branch / symbolic-ref evasions), --no-verify
#     (incl. core.hooksPath / HUSKY=0 sneak-arounds), writes to .git/ and the bd-managed .beads/
#     ledger, secret-
#     shaped strings, and self-protection of the ENFORCEMENT files (.claude/hooks/**,
#     .claude/settings*.json, harness/**, .harness/**).
#   TASK-SCOPED (only when .harness/active-task.json exists): writes outside sandbox/ (incl. a
#     '..'-traversal fail-closed guard — `sandbox/../x` matches the `sandbox/*` glob).
#   INTAKE-SCOPED (only when .harness/active-intake.json exists and no build
#     task is active): writes confined to specs/** by ALLOWLIST — permit specs/**, deny the
#     rest (closed by construction; an unanticipated path cannot outrun it), explicitly
#     closing the .claude/agents|skills|commands self-rewrite hole that ENFORCE_RE does not
#     cover. Applies to tool writes (Write/Edit/MultiEdit/NotebookEdit) AND Bash-issued
#     writes (redirects + mutators, via the same argv-aware walkers as the universal pass).
# JWT-shaped strings WARN, not block. Self-protection is bypassable ONLY via an explicit,
# logged FORGE_ALLOW_HOOK_EDIT=1 — never for .git/ or the .beads/ ledger. (The vault is NOT a forge
# component and is NOT adjudicated here.)
# NOTE: .claude/worktrees/** is task WORKSPACE, not an enforcement path — its sandbox/ is writable.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"
# KEYSTONE: the floor's functions live in lib.sh. If lib.sh is
# missing/unreadable/failed to load (e.g. a git rm / git apply rename deleted it mid-session — which the
# SessionStart witness, running only at start, never re-checks), the bare source above leaves every forge_*
# undefined and the hook would fall through to exit 0 = ALLOW-ALL. A deleted/broken floor must DENY, not
# allow. v2: fail closed unless BOTH an EARLY core fn (forge_deny) AND the LAST fn the hook depends on
# (forge_check_git — defined after every other walker the hook calls) are present, so a lib MISSING *or
# PARTIALLY loaded* (truncated/corrupted anywhere between them — defining forge_deny but not a later walker)
# is caught, closing the same fail-open shape the keystone exists to reject. (multi-arg `command -v` is
# unsafe — it returns 0 if ANY name resolves — so AND two single-name checks.) Fires ONLY on a genuine
# load failure; a present valid lib.sh is byte-identical normal operation.
command -v forge_deny >/dev/null 2>&1 && command -v forge_check_git >/dev/null 2>&1 && command -v forge_check_bd >/dev/null 2>&1 || { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"agentic-builder-forge: BLOCKED — deny-floor lib.sh missing or partially loaded (fail closed)"}}\n'; exit 2; }
# Fail-closed (LOW): jq is the parser for every rule below — absent jq makes forge_json return empty
# for the tool name / command / file path, and the whole hook would fall through to ALLOW. Refuse instead.
command -v jq >/dev/null 2>&1 || { printf 'agentic-builder-forge: BLOCKED — jq not found on PATH; the deny hook cannot parse tool input (fail closed).\n' >&2; exit 2; }
forge_read_input

TOOL="$(forge_json '.tool_name')"
CMD="$(forge_json '.tool_input.command')"
FILE_PATH="$(forge_json '.tool_input.file_path')"
# NotebookEdit names its target notebook_path, not file_path — without this fallback the tool slips
# EVERY path rule below despite being in the PreToolUse matcher (closed-by-construction: no
# matched write tool may bypass the path tier).
[ -z "$FILE_PATH" ] && FILE_PATH="$(forge_json '.tool_input.notebook_path')"
# FILE_PATH tier (the keystone): normalize the tool-write path through
# the SAME canonical normalizer the Bash floor uses (//->/ , /./->/, trailing /.), so the Write/Edit/Notebook
# tool path — the agent's PRIMARY edit vector — cannot defeat the two-segment self-protection patterns
# (.claude/hooks/, .claude/settings) with path noise (`Write .claude/./hooks/lib.sh` was ALLOW — a one-tool
# floor-disable on this previously-untested tier; the Bash tier got this via forge_path_class). `..` is left
# intact for the existing *..* fail-closed arms (textual `..` resolution is symlink-unsafe — see forge_norm_path).
[ -n "$FILE_PATH" ] && FILE_PATH="$(forge_norm_path "$FILE_PATH")"
# new_source is NotebookEdit's written-content field — same unread-field class as notebook_path above:
# without it a secret written into a notebook cell slips the content scan.
CONTENT="$(printf '%s' "${HOOK_INPUT:-}" | jq -r '[.tool_input.content,.tool_input.file_text,.tool_input.new_string,.tool_input.new_source,(.tool_input.edits[]?.new_string)]|map(select(.!=null))|join("\n")' 2>/dev/null)"
ALLOW_HOOK_EDIT="${FORGE_ALLOW_HOOK_EDIT:-0}"

# Enforcement files that the agent must never edit (self-protection). Worktrees are excluded.
ENFORCE_RE='(^|/)\.claude/hooks/|(^|/)\.claude/settings(\.local)?\.json|(^|/)harness/|(^|/)\.harness/'

# Work-root confinement: resolve the active task's write-area ONCE, from the forge-side sentinel ONLY.
# The sentinel (.harness/active-task.json) is agent-UNWRITABLE (ENFORCE_RE), so work_root cannot be
# influenced by the agent. work_root is the sentinel's RESOLVED-ABSOLUTE worktree path for a target
# build; a self-build sentinel OMITS it (legacy sandbox/ mode, byte-identical). Resolution NEVER denies
# here — the write tiers below act on these flags, so a malformed sentinel denies WRITES (fail closed),
# never reads. Empty/absent work_root => legacy sandbox/; present-but-non-absolute => deny (the fallback
# is ALWAYS to the stricter state, never permissive).
TASK_ACTIVE=0
TASK_WORK_ROOT=""
TASK_SENTINEL_BAD=0
if forge_task_active; then
  TASK_ACTIVE=1
  if _sj="$(cat "$(forge_sentinel)" 2>/dev/null)" && printf '%s' "$_sj" | jq -e . >/dev/null 2>&1; then
    TASK_WORK_ROOT="$(printf '%s' "$_sj" | jq -r '.work_root // empty' 2>/dev/null)"
  else
    TASK_SENTINEL_BAD=1
  fi
fi

# ---------------- secret-shaped strings (command OR written content) ----------------
SCAN="$CMD"$'\n'"$CONTENT"
if printf '%s' "$SCAN" | grep -Eq 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+'; then
  printf 'agentic-builder-forge: WARNING — JWT-shaped string detected (allowed; review before commit).\n' >&2
fi
if printf '%s' "$SCAN" | grep -Eq '(sk-[A-Za-z0-9]{20,}|gh[opsur]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN[A-Z ]*PRIVATE KEY-----)'; then
  forge_deny "secret-shaped string detected (no secrets in code or commands)"
fi

# ---------------- path-based rules (Write / Edit / MultiEdit / NotebookEdit) ----------------
if [ -n "$FILE_PATH" ]; then
  # No vault adjudication here — a sibling vault (e.g. ../my-vault) is an external target,
  # NOT a forge component (the old blunt grep over-blocked vault READS and made a false "protected"
  # claim it could not keep). A '..'-bearing vault path still denies via the general traversal rule
  # below; an absolute vault path is out of forge scope.
  # Tier-unification: route the .git/.beads/enforcement classification through
  # the SHARED forge_enforce_class — the SAME classifier the BASH tier uses via forge_path_class — instead of
  # the three separate slash-terminated greps (the old ENFORCE_RE etc. below is now superseded for this tier).
  # The FILE_PATH tier thus inherits the bare-dir, nested-bare, and normalization arms WHOLESALE
  # and CANNOT diverge from the BASH tier on the enforce SET (closing the cross-tier divergence class — the
  # normalization gap + bare-dir + ..-parity — structurally, one classifier not two that drift).
  # FILE_PATH is already normalized (above). glob/$ chars are LITERAL in a tool file_path (Next.js
  # app/[id]/page.tsx, foo[1].txt) — NOT treated as ambiguous here (that is the shell tier's job); only `..`
  # is fail-closed, matching the BASH tier's forge_path_class */../* ambiguous arm.
  # SEGMENT-bounded .. (the forge_path_class */../* form) — NOT a *..* substring, which false-DENYs a literal
  # `...` filename like a Next.js catch-all route app/[...slug]/page.tsx. Matches a real /../ traversal segment.
  case "/$FILE_PATH/" in */../*) forge_deny "a write path with a '..' traversal segment cannot be verified — denied ($FILE_PATH)" ;; esac
  case "$(forge_enforce_class "$FILE_PATH")" in
    git) forge_deny "writing under .git/ is not allowed ($FILE_PATH)" ;;
    beads) forge_deny "the .beads/ ledger is bd-managed — mutate via bd, never a raw edit (no agent-tool write to the ledger) ($FILE_PATH)" ;;
    enforce)
      if [ "$ALLOW_HOOK_EDIT" = "1" ]; then
        forge_log_bypass "$TOOL $FILE_PATH"
      else
        forge_deny "editing enforcement/harness files is the cardinal-rule violation ($FILE_PATH); set FORGE_ALLOW_HOOK_EDIT=1 for supervised maintenance"
      fi ;;
  esac
  if [ "$TASK_ACTIVE" = 1 ]; then
    proj="${CLAUDE_PROJECT_DIR:-$(forge_main_root 2>/dev/null || pwd)}"
    # A malformed task sentinel cannot tell us the write-area — deny the WRITE (fail closed).
    [ "$TASK_SENTINEL_BAD" = 1 ] && forge_deny "during a task, the work-confinement sentinel is unreadable/malformed — write denied (fail closed)"
    case "$FILE_PATH" in
      # '..' fails closed — `sandbox/../README.md` (or `$wt/../x`) matches the prefix glob, a live
      # traversal escape of the confinement until this arm (probe-proven, then fixture-pinned).
      *..*) forge_deny "during a task, a write path containing '..' cannot be verified against the work-root confinement — denied (attempted: $FILE_PATH)" ;;
    esac
    if [ -z "$TASK_WORK_ROOT" ]; then
      # self-build (legacy: the sentinel carries no work_root) — sandbox/ confinement, byte-identical.
      case "$FILE_PATH" in
        sandbox/* | ./sandbox/* | "$proj"/sandbox/*) : ;;
        *) forge_deny "during a task, writes must stay under sandbox/ (attempted: $FILE_PATH)" ;;
      esac
    else
      # target-build — ONLY an ABSOLUTE path under the resolved-absolute worktree is permitted (an
      # ALLOWLIST, exactly like the legacy sandbox/ and intake specs/ arms). RELATIVE paths are DENIED:
      # model (c) launches the agent CONTROL-PLANE-SIDE (run-task.sh at the main checkout root, NOT the
      # worktree — hooks load from the launch cwd), so a relative path resolves against the wrong cwd and
      # cannot be verified to land in the worktree. The agent addresses the target worktree by absolute
      # path. '..' was denied above; universal .git/.beads/ENFORCE_RE denies ran ABOVE and still
      # subtract. A non-absolute work_root is itself unverifiable -> deny (fail closed).
      case "$TASK_WORK_ROOT" in
        /*) : ;;
        *) forge_deny "during a task, work_root is not an absolute path — cannot verify the confinement, denied (fail closed)" ;;
      esac
      case "$FILE_PATH" in
        "$TASK_WORK_ROOT"/*) : ;;
        *) forge_deny "during a task, target-build writes must be an absolute path under the task worktree (attempted: $FILE_PATH; work_root=$TASK_WORK_ROOT)" ;;
      esac
    fi
  fi
  # INTAKE-SCOPED specs/** ALLOWLIST. Active only while the intake sentinel exists and
  # no build task is (the build's sandbox confinement above wins — proven by the builder-guard
  # fixtures, so intake confinement can never break the build loop). Permit specs/**, deny everything
  # else: closed by construction, an unanticipated top-level path cannot outrun it. The dedicated
  # self-rewrite deny fires first with a named reason: ENFORCE_RE covers only .claude/hooks/ +
  # settings*.json, so the Architect's own contract surfaces (.claude/agents|skills|commands) were
  # writable during intake until this gate. A path carrying ".." cannot be verified against a
  # case-glob allowlist (specs/../x matches specs/*) — fail closed.
  if forge_intake_active && ! forge_task_active; then
    proj="${CLAUDE_PROJECT_DIR:-$(forge_main_root 2>/dev/null || pwd)}"
    printf '%s' "$FILE_PATH" | grep -Eq '(^|/)\.claude/(agents|skills|commands)/' &&
      forge_deny "during intake, the role/skill/command contract surfaces are immutable — a write into .claude/agents|skills|commands is the self-rewrite hole fx-w5x closes (attempted: $FILE_PATH)"
    case "$FILE_PATH" in
      *..*) forge_deny "during intake, a write path containing '..' cannot be verified against the specs/** allowlist — denied (attempted: $FILE_PATH)" ;;
      specs/* | ./specs/* | "$proj"/specs/*) : ;;
      *) forge_deny "during intake, writes are confined to specs/** (fx-w5x allowlist; attempted: $FILE_PATH) — the Architect authors the spec tree only" ;;
    esac
  fi
fi

# ---------------- command-based rules (Bash) ----------------
if [ -n "$CMD" ]; then
  # A sibling vault (e.g. ../my-vault) is an EXTERNAL target repo, NOT a forge component —
  # the floor does NOT adjudicate vault writes. The old blunt `grep <vault-path> -> deny` over-blocked
  # vault READS (`cat ../my-vault/x`) and made a false "vault protected" claim it could not keep
  # (vault-write bypasses proved the claim leaky). Vault write-protection, if wanted, is the
  # target's or the OS container's concern. A relative `../my-vault/...` write still fails the
  # general `..`-unverifiable rule (not a vault claim); an absolute vault path is out of scope.

  # --no-verify and its sneak-arounds
  printf '%s' "$CMD" | grep -Eq -- '--no-verify' && forge_deny "--no-verify is not allowed"
  printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+commit([[:space:]]+[^|;&]*)?[[:space:]]+-[A-Za-z]*n' && forge_deny "git commit -n (no-verify) is not allowed"
  printf '%s' "$CMD" | grep -Eq 'core\.hooksPath' && forge_deny "changing core.hooksPath (disabling git hooks) is not allowed"
  printf '%s' "$CMD" | grep -Eq '(^|[^A-Za-z_])HUSKY=0' && forge_deny "HUSKY=0 (disabling git hooks) is not allowed"
  # intake.sh ratify is the HUMAN's Gate-A sign-off — the agent session must not self-ratify.
  # DEFENSE-IN-DEPTH ONLY: the real guarantee is cmd_ratify's own TTY gate (the agent's
  # Bash is non-TTY), since a string matcher cannot catch `bash wrapper.sh`. Word-boundary anchor —
  # ratify followed by EOL or ANY non-word byte, so `ratify;` / `ratify&` / `ratify||` / `bash -c
  # "...ratify"` are caught, not just a trailing space.
  printf '%s' "$CMD" | grep -Eq '(^|[^A-Za-z0-9._-])intake\.sh[[:space:]]+ratify(-breakdown)?($|[^[:alnum:]_-])' && forge_deny "intake.sh ratify / ratify-breakdown is reserved for a human at the terminal — the agent session must not self-ratify Gate A / A′ (cp-gateA')"
  # Narrow intake-adjacent fail-closed: a command naming BOTH intake.sh AND ratify that ALSO routes through
  # an opaque vector (command-substitution / backtick / eval / pipe-into-shell / -c / variable indirection)
  # cannot be verified not to self-ratify — deny. Scoped to `ratify`, so legit `intake.sh start "$OBJ"` /
  # `intake.sh analyze "$(…)"` (no ratify token) are untouched.
  if printf '%s' "$CMD" | grep -Eq 'intake\.sh' &&
    printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])ratify(-breakdown)?([^[:alnum:]_-]|$)' &&
    printf '%s' "$CMD" | grep -Eq '`|(^|[[:space:]])eval([[:space:]]|$)|\|[[:space:]]*(sh|bash|dash|zsh|ksh|busybox)([[:space:]]|$)|(^|[[:space:]])(sh|bash|dash|zsh|ksh|busybox)[[:space:]]+[^|;&]*-[A-Za-z]*c|\$[A-Za-z_{(]'; then
    forge_deny "an intake.sh ratify routed through eval / a subshell / -c / a pipe-into-shell / variable indirection cannot be verified — ratify is reserved for a human at the terminal (cp-6)"
  fi

  # git push protections — argv-aware, per-segment (replaces the whole-command scan).
  forge_check_push "$CMD"
  printf '%s' "$CMD" | grep -Eq 'symbolic-ref[[:space:]]+[^|;&]*(refs/heads/)?(main|master)' && forge_deny "repointing HEAD to main/master is not allowed"
  # Commit-to-main guard: a DIRECT `git commit`/`--amend` on main/master is denied early with a named reason
  # (the deny-hook TIER; argv-aware, branch read live + fail-closed). The git pre-commit hook is the
  # all-actors backstop; this is the install-free guard for the agent's tool-path commit.
  forge_check_commit "$CMD"

  # A DIRECT `git checkout <ref> -- <floor>` / `git restore <floor>`
  # overwrites the deny floor / .git / .beads / harness from a ref or the index — argv-aware, per-segment,
  # pathspec-scoped (only a floor-targeting pathspec denies; a benign branch switch carries none).
  forge_check_git "$CMD"

  # Deny the agent's DIRECT bd close-verbs (close/done/import/supersede/duplicate, update --status
  # closed). The reconcile SUBPROCESS close is invisible to PreToolUse (subprocess-exempt), so this over-
  # blocks zero automation; FORGE_ALLOW_BD_CLOSE=1 opens a supervised, actor-logged triage door.
  forge_check_bd "$CMD"

  # recursive-force rm outside sandbox/
  forge_check_rm "$CMD"

  # Launch-time half: BEST-EFFORT defense-in-depth deny of an
  # env-assignment prefix that shims the launch interpreter/loader. ALLOWLIST
  # INVERSION: a leading assignment before a launch denies unless its NAME is benign-allowlisted
  # (FORGE_*/BD_*/TARGET/…); LD_*/GCONV_PATH/BASH_ENV/ENV/future loader vars fall through to deny
  # WITHOUT enumeration. PATH is scoped to a harness entrypoint. NOT airtight — the OS container
  # is the actual launch-time boundary; obfuscation/here-string/procsub conceded.
  forge_check_envprefix "$CMD"

  # .git/ + enforcement writes — argv-aware target resolution.
  forge_check_writes "$CMD"

  # TASK-SCOPED Bash-write confinement — the SAME work_root allowlist as the path tier,
  # for Bash-issued writes (redirects + mutators). Until now the task tier confined ONLY the tool-write
  # path; task-time Bash writes outside sandbox/ were a no-op-permit (the gap that let `cp evil /abs/x`
  # route around the confinement). Mirrors the proven intake specs/** override onto the task
  # tier: reuses the universal argv-aware walkers VERBATIM by swapping forge_classify_target for a
  # work-root-strict classifier; the swap exists only on this branch, AFTER the universal pass above
  # completed (its verdicts/reasons untouched — reaching here means every target was 'ok' there). The
  # malformed-sentinel deny lives INSIDE the ok) branch (a write target), so it denies WRITES not reads;
  # a non-absolute work_root denies (fail closed); empty work_root => legacy sandbox/. SCOPE: this covers
  # the recognized redirect/mutator vectors (the walker's argv model — the same set the universal/intake
  # passes cover); exotic writers (python -c, tar, ...) are out of textual scope and are confined by the
  # OS container layer (FORGE_SANDBOX), which is the complete boundary for execution.
  if [ "$TASK_ACTIVE" = 1 ]; then
    proj="${CLAUDE_PROJECT_DIR:-$(forge_main_root 2>/dev/null || pwd)}"
    forge_classify_target() {
      local tgt
      case "$(forge_path_class "$1")" in
        ok)
          [ "$TASK_SENTINEL_BAD" = 1 ] && forge_deny "during a task, the work-confinement sentinel is unreadable/malformed — Bash write denied (fail closed)"
          tgt="$(forge_unquote "$1")"
          case "$tgt" in
            *..*) forge_deny "during a task, a Bash write target containing '..' cannot be verified against the work-root confinement — denied (target: $tgt)" ;;
          esac
          if [ -z "$TASK_WORK_ROOT" ]; then
            case "$tgt" in
              sandbox/* | ./sandbox/* | "$proj"/sandbox/*) : ;;
              *) forge_deny "during a task, Bash writes are confined to sandbox/ (target: $tgt)" ;;
            esac
          else
            # target-build — ALLOWLIST: only an absolute target under the worktree passes; relative
            # targets are unverifiable from the control-plane-side cwd (see the path tier) -> deny.
            case "$TASK_WORK_ROOT" in /*) : ;; *) forge_deny "during a task, work_root is not an absolute path — cannot verify Bash write, denied (fail closed)" ;; esac
            case "$tgt" in
              "$TASK_WORK_ROOT"/*) : ;;
              *) forge_deny "during a task, target-build Bash writes must be an absolute path under the task worktree (target: $tgt; work_root=$TASK_WORK_ROOT)" ;;
            esac
          fi
          ;;
        *) : ;; # git/beads/enforce/ambiguous already denied (and exited) in the universal pass
      esac
    }
    forge_check_writes "$CMD"
  fi

  # INTAKE-SCOPED Bash-write confinement — the same specs/** allowlist as the path tier,
  # for Bash-issued writes (redirects, cp/mv/tee/sed -i/dd/...). A confinement that catches tool calls
  # but not `echo > file` is bypassable, the same class as the ratify command path. Reuses the
  # universal pass's argv-aware walkers VERBATIM by re-running forge_check_writes with
  # forge_classify_target swapped for an intake-strict classifier; the swap exists only on this branch
  # of this single hook invocation, AFTER the universal pass above has fully completed (so its verdicts
  # and reasons are untouched — reaching this line means every target was 'ok' there; ambiguous targets
  # were already denied fail-closed).
  # Operand-conservative BY DESIGN: mutators whose argv mixes non-path operands (a sed script, a chmod
  # mode, a truncate size) judge those operands against the allowlist too and therefore DENY during
  # intake — fail closed; the Architect edits specs via the Write/Edit tools (or plain redirects/cp/mv
  # within specs/**), never via sed -i. Fixture-pinned, not accidental.
  if forge_intake_active && ! forge_task_active; then
    proj="${CLAUDE_PROJECT_DIR:-$(forge_main_root 2>/dev/null || pwd)}"
    forge_classify_target() {
      local tgt
      case "$(forge_path_class "$1")" in
        ok)
          tgt="$(forge_unquote "$1")"
          case "$tgt" in
            *..*) forge_deny "during intake, a Bash write target containing '..' cannot be verified against the specs/** allowlist — denied (target: $tgt)" ;;
            specs/* | ./specs/* | "$proj"/specs/*) : ;;
            *) forge_deny "during intake, Bash writes are confined to specs/** (fx-w5x allowlist; target: $tgt)" ;;
          esac
          ;;
        *) : ;; # git/beads/enforce/ambiguous already denied (and exited) in the universal pass
      esac
    }
    forge_check_writes "$CMD"
  fi
fi

exit 0
