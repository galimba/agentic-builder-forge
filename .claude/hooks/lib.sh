#!/usr/bin/env bash
# Shared helpers for agentic-builder-forge hooks. SOURCED, not executed.
# No `set -e`/`set -u`: a hook must never crash into a non-0/2 exit (that would be a
# non-blocking "proceed with error" = fail-OPEN). Read defensively; end callers with `exit 0`.

# Read all of stdin once into HOOK_INPUT.
forge_read_input() { HOOK_INPUT="$(cat)"; }

# jq-extract a path from HOOK_INPUT; empty string if absent/invalid.
forge_json() { printf '%s' "${HOOK_INPUT:-}" | jq -r "$1 // empty" 2>/dev/null; }

# Absolute path of the MAIN checkout root — correct even inside a linked worktree
# (CLAUDE_PROJECT_DIR points at the worktree, so we resolve the shared .git instead).
forge_main_root() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  dirname "$common"
}

# Harness runtime dir + task sentinel (live in the parent checkout; gitignored).
forge_harness_dir() {
  [ -n "${FORGE_HARNESS_DIR:-}" ] && { printf '%s' "$FORGE_HARNESS_DIR"; return 0; }
  local r
  r="$(forge_main_root 2>/dev/null)" || return 1
  printf '%s/.harness' "$r"
}
forge_sentinel()    { local d; d="$(forge_harness_dir 2>/dev/null)" || return 1; printf '%s/active-task.json' "$d"; }
forge_task_active() { local s; s="$(forge_sentinel 2>/dev/null)" || return 1; [ -n "$s" ] && [ -f "$s" ]; }
# Intake sentinel helpers — a SEPARATE lifecycle from the build sentinel (active-task.json).
# active-intake.json is armed by `intake.sh start` and carries {spec,slug,objective,targets,mode,phase,...}.
forge_intake_sentinel() { local d; d="$(forge_harness_dir 2>/dev/null)" || return 1; printf '%s/active-intake.json' "$d"; }
forge_intake_active()   { local s; s="$(forge_intake_sentinel 2>/dev/null)" || return 1; [ -n "$s" ] && [ -f "$s" ]; }
forge_intake_phase()    { local s; s="$(forge_intake_sentinel 2>/dev/null)" || return 1; [ -f "$s" ] || return 1; jq -r '.phase // empty' "$s" 2>/dev/null; }

# forge_validate_selector <value> <allowlist...> — FOLD #14: membership test for an
# attacker-influenceable SELECTOR (TARGET / *_BACKEND) BEFORE it reaches an eval/indirect-expansion sink.
# PURE string equality (no eval, no glob): a metacharacter value ($()/`/{}/:/glob) simply fails to match
# and returns 1, so the caller refuses instead of substituting. The allowlist is supplied BY THE CALLER
# from a TRUSTED source (the config FILE's declared keys / a fixed backend set) — never derived from the
# attacker-influenceable environment. Empty allowlist => no match => return 1 (fail-closed).
forge_validate_selector() {
  local _val="$1"; shift
  local _item
  for _item in "$@"; do
    [ "$_val" = "$_item" ] && return 0
  done
  return 1
}

# Load TEST_CMD/LINT_CMD/FORMAT_CMD/SANDBOX_GLOB from targets.config (config-driven;
# hooks hardcode NO commands).
forge_load_target() {
  # targets.config is a HOST-EXEC surface (its commands are eval'd host-side) —
  # resolve it from forge_main_root ONLY, never from CLAUDE_PROJECT_DIR / the worktree (PROBE-D).
  # Returns 1 when the root or the file is unresolvable; callers decide fail-open vs fail-closed
  # (the Stop gate fail-closes under FORGE_UNATTENDED=1 — R-16).
  local root cfg _targets
  root="$(forge_main_root 2>/dev/null)" || return 1
  [ -n "$root" ] || return 1
  cfg="$root/harness/targets.config"
  [ -f "$cfg" ] || return 1
  # shellcheck disable=SC1090
  . "$cfg"
  # FOLD #14: TARGET is an attacker-influenceable selector that flows into the eval-indirection
  # below AND into `eval "$TEST_CMD"` host-side (run-task.sh cmd_finish). Validate it ONCE, at the root,
  # against the targets DECLARED IN THE CONFIG FILE — parsed from the FILE, never the sourced environment,
  # so an exported <name>_TEST_CMD cannot extend the allowlist — BEFORE any eval. A metacharacter/foreign
  # TARGET fails the membership test and forge_load_target returns 1 (the existing failure the callers
  # already handle: the Stop gate fail-closes under FORGE_UNATTENDED=1). This closes BOTH sinks at once —
  # the metacharacter `$()` at the eval (lib.sh:50) and the poisoned <TARGET>_TEST_CMD indirection.
  _targets="$(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)_TEST_CMD=.*/\1/p' "$cfg" 2>/dev/null)"
  # shellcheck disable=SC2086
  forge_validate_selector "${TARGET:-}" $_targets || return 1
  eval "TEST_CMD=\${${TARGET}_TEST_CMD:-}"
  eval "LINT_CMD=\${${TARGET}_LINT_CMD:-}"
  eval "FORMAT_CMD=\${${TARGET}_FORMAT_CMD:-}"
  eval "SANDBOX_GLOB=\${${TARGET}_SANDBOX_GLOB:-}"
}

# Append a line to the hook-edit bypass audit log (used when FORGE_ALLOW_HOOK_EDIT=1).
forge_log_bypass() {
  local d; d="$(forge_harness_dir 2>/dev/null)" || return 0
  mkdir -p "$d" 2>/dev/null
  printf '%s\t%s\n' "$(date -u +%FT%TZ 2>/dev/null || printf now)" "$1" >>"$d/hook-edit-bypass.log" 2>/dev/null
  return 0
}

# Commit-to-main guard: append to the main-commit escape audit log (used when FORGE_ALLOW_MAIN_MERGE=1 permits
# a commit while HEAD is on main/master — the supervised merge-finalize door). ISO-42001 evidence;
# mirrors forge_log_bypass. Records actor + context so a main-branch commit is NEVER silent.
forge_log_main_escape() {
  local d; d="$(forge_harness_dir 2>/dev/null)" || return 0
  [ -n "$d" ] || return 0
  mkdir -p "$d" 2>/dev/null
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ 2>/dev/null || printf now)" "${USER:-$(id -un 2>/dev/null || printf unknown)}" "$1" >>"$d/main-commit-escape.log" 2>/dev/null
  return 0
}

# DENY a PreToolUse tool call. Emits the documented permissionDecision:"deny" (blocks even
# under --dangerously-skip-permissions); falls back to fail-closed exit 2 if jq is unavailable.
forge_deny() {
  local out
  if out="$(jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
  fi
  printf 'agentic-builder-forge: BLOCKED — %s\n' "$1" >&2
  exit 2
}

# BLOCK a Stop or PostToolUse. Emits {"decision":"block"}; exit-2 fallback.
forge_block() {
  local out
  if out="$(jq -nc --arg r "$1" '{decision:"block",reason:$r}' 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
  fi
  printf '%s\n' "$1" >&2
  exit 2
}

# ---------------- recursive-delete safety (argv-aware; replaces the old substring scan) ----------------
# Fixes #6 (filename fragments such as `agentic-builder-forge` misread as -r/-f) and closes the -R / \rm /
# /bin/rm / find-delete / post-`--`-target leaks. FAILS CLOSED (forge_deny) on anything it cannot
# resolve: an opaque command word ($CMD, $(which rm)), variable/substituted/glob targets, eval,
# interpreter -c bodies, pipes into a shell, and xargs-fed deletes. Deleters recognized: rm, shred,
# unlink, and `find … -delete | -exec rm`. Force = -f/--force only (rm has no -F); recursive = -r/-R/--recursive.

# Strip one layer of matched surrounding quotes from a token.
forge_unquote() {
  local t="$1"
  case "$t" in
    \"*\") t="${t#\"}" && t="${t%\"}" ;;
    \'*\') t="${t#\'}" && t="${t%\'}" ;;
  esac
  printf '%s' "$t"
}

# basename with a leading backslash stripped: \rm -> rm, /bin/rm -> rm.
forge_basename() {
  local b
  b="$(forge_unquote "$1")"
  b="${b##*/}"
  printf '%s' "${b#\\}"
}

# Is the (unquoted, basename-resolved) command word a recognized file deleter?
forge_is_deleter() { case "$(forge_basename "$1")" in rm | shred | unlink) return 0 ;; *) return 1 ;; esac; }

# 0 (= escapes / dangerous) unless the target is PROVABLY confined to sandbox/. Globs, ~, $vars,
# backticks and any `..` segment all count as escaping (cannot be bounded). Normalizes . / .. textually;
# never touches the filesystem.
forge_rm_escapes() {
  local p
  p="$(forge_unquote "$1")"
  case "$p" in '' | *'*'* | *'?'* | *'['* | '~'* | *'$'* | *'`'*) return 0 ;; esac
  p="${p#./}"
  case "/$p/" in */../*) return 0 ;; esac
  case "$p" in sandbox/*) return 1 ;; *) return 0 ;; esac
}

# Trailing group-close: a subshell ( ... ) leaves its close-paren as the FINAL token — the
# &&/||/;/| splitter does not split on parens, and a brace group always carries a ';' (so it is split and never
# arrives here with a trailing '}'). That trailing ')' displaces the real dest for last-operand writers
# (cp/install/ln/rsync) and the push refspec operand. When (and ONLY when) the segment is GROUPED — its first
# token opens with ( or { — drop trailing bare close tokens and strip a glued trailing ) / } so operand/refspec
# classification sees the real final argument. Gated on the open so a legitimate operand that merely ends in )
# (a filename) is never touched. Operates on the CALLER's `toks`/`n` via bash dynamic scope — every *_seg
# walker declares those names — so the leading-skip (in each loop) and this trailing-trim share ONE definition
# and cannot drift (the tier-unification principle, applied to the grouping class).
forge_strip_group_close() {
  [ "${n:-0}" -gt 0 ] || return 0
  case "${toks[0]}" in '('* | '{'*) ;; *) return 0 ;; esac
  while [ "$n" -gt 0 ]; do
    case "${toks[$((n - 1))]}" in
      ')' | '}' | '))' | '}}') unset 'toks[$((n - 1))]'; n=$((n - 1)) ;;
      *')' | *'}') toks[$((n - 1))]="${toks[$((n - 1))]%?}"; break ;;
      *) break ;;
    esac
  done
}

# The runner-value class: resolve the command word past a
# launcher/runner wrapper that takes OPTIONS (and, for timeout/chrt/flock, a mandatory positional) before its
# command. The prior skip arms treated nice|ionice|stdbuf|time|setsid|command as ZERO-ARG and timeout|chrt|flock
# as fixed-arity (+2), so an OPTION token masqueraded as the command word and the real cp/find/git was never
# classified: `nice -n5 cp <floor>` / `stdbuf -oL find .git -delete` / `time -p git push origin main` /
# `timeout -s9 5 cp <floor>` / `chrt -f 1 cp <floor>` all ALLOWed — a TIER-WIDE floor-disable
# (write+delete+git+push+commit). ONE grammar definition shared by all five *_seg walkers via bash dynamic
# scope on toks/n/i (the forge_strip_group_close tier-unification model) so they cannot drift. The wrapper word
# is ALWAYS consumed first (an unknown wrapper degrades to the old zero-arg skip — never an infinite loop).
# Per-wrapper VALUE-option set: `time -p` is valueless but `ionice -p PID`/`-c N` take a value (the collision a
# generic loop gets wrong). Glued values (-oL/-n5/-c2) consume ONE token; detached (-o L/-n 5/-c 2) consume TWO.
# After options, NPOS mandatory positionals (timeout DURATION, chrt PRIO, flock FILE) are consumed; the next
# bare token is the command word, re-examined by the caller's loop — so stacked wrappers (`nice -n5 stdbuf -oL
# cp`) compose. RESIDUALS (container-deferred): unshare|nsenter (optional-argument opts, e.g. `nsenter
# -m[=file]`, not argv-modelable cleanly); a path-qualified runner in a non-mutator walker (pre-existing C-4
# partial scope — only the WRITE walker basename-matches wrapper words); an interpreter -c STRING (bash/sh and
# flock -c — the segment splitter does not recurse into command strings, a broad pre-existing residual). sudo
# stays zero-arg in the rm/write/push/git/mutator walkers (blocked upstream by the platform safety hook); the
# bd walker (forge_check_bd_seg) additionally routes sudo through this helper as done-edge close defense-in-
# depth, so `sudo -u X bd close` resolves to bd.
forge_skip_runner() {
  local w vopts="" npos=0 first rest p=0
  w="$(forge_basename "$1")"
  i=$((i + 1))
  case "$w" in
    nice) vopts=' -n --adjustment ' ;;
    ionice) vopts=' -c -n -p -P -u --class --classdata --pid --pgid --uid ' ;;
    stdbuf) vopts=' -i -o -e --input --output --error ' ;;
    time) vopts=' -f -o --format --output ' ;;
    doas) vopts=' -u -C ' ;;
    # sudo's VALUE-taking options only (so a boolean like -n does NOT consume the following
    # command word). npos=0 — sudo takes no mandatory positional before the command. Reached ONLY from the bd
    # walker (the other *_seg walkers keep sudo in their zero-arg arm), so this is bd-close defense-in-depth,
    # not a global sudo model. -h is deliberately left boolean (its -h=help / -h host ambiguity is harmless).
    # The fundamental residual is path-qualified sudo (`/usr/bin/sudo`) evading the word-match — conceded (sudo
    # is upstream-blocked by the platform safety hook regardless; adversarially reviewed).
    sudo) vopts=' -u -g -U -C -p -r -t -T -D -R --user --group --other-user --close-from --prompt --role --type --command-timeout --chdir --chroot ' ;;
    timeout) vopts=' -s --signal -k --kill-after '; npos=1 ;;
    chrt) vopts=' -T -P -D --sched-runtime --sched-deadline --sched-period '; npos=1 ;;
    flock) vopts=' -w --timeout -E --conflict-exit-code -c --command '; npos=1 ;;
    setsid | command) vopts=' ' ;;
    # Common exec/tracing wrappers that EXEC their remaining args as
    # a command (host-side; the OS container is not built). ENUMERATION is the correct primitive — the
    # discriminator is the wrapper NAME (strace cp <floor> vs docker cp / git mv / apt install are structurally
    # identical <word> <writer-name> <args>, so a resolve-to-writer re-enter over-blocks the toolchain AND
    # regresses the opaque-command-word floor; the established structural->enumeration
    # pivot, same as exec/busybox). Each carries its VALUE-OPTION grammar (a missed value-taker desyncs the skip
    # onto the option's value, not the command). Long value-takers are listed because these accept DETACHED long
    # options (strace --output FILE); glued --opt=value is handled by the --*=* arm. Novel/unknown exec-wrappers
    # (toybox-class) stay the documented container-deferred residual — the unbounded tail is the container's.
    strace) vopts=' -a -b -e -E -I -o -O -p -P -s -S -U -u -X --abbrev --absolute-timestamps --attach --columns --const-print-style --daemonize --decode-fds --decode-pids --detach-on --env --fault --inject --interruptible --kvm --output --quiet --raw --read --signal --stack-trace-frame-limit --status --string-limit --strings-in-hex --summary-columns --summary-sort-by --summary-syscall-overhead --syscall-limit --trace --trace-fds --trace-path --user --verbose --write ' ;;
    ltrace) vopts=' -a -A -D -e -l -n -o -p -s -u -F -x -X -w --align --config --indent --library --output --where ' ;;
    fakeroot) vopts=' -b -f -i -l -s --fd-base --faked --lib --load --save ' ;;
    valgrind) vopts=' --log-file --xml-file --error-exitcode --num-callers --suppressions --tool --log-fd --xml-fd --max-stackframe --main-stacksize ' ;;
    watch) vopts=' -n --interval ' ;;
    eatmydata) vopts=' ' ;;
    taskset) vopts=' '; npos=1 ;;
    chroot) vopts=' --groups --userspec '; npos=1 ;;
    setarch) vopts=' '; case "${toks[$i]:-}" in -* | '') ;; *) i=$((i + 1)) ;; esac ;;
    numactl) vopts=' -i -p -P -C -N -m --interleave --preferred --preferred-many --physcpubind --cpunodebind --membind ' ;;
    setpriv) vopts=' --ambient-caps --inh-caps --bounding-set --ruid --euid --rgid --egid --reuid --regid --groups --securebits --pdeathsig --selinux-label --apparmor-profile ' ;;
    *) return 0 ;;
  esac
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      --) i=$((i + 1)); break ;;
      --*=*) i=$((i + 1)) ;;
      --*) case "$vopts" in *" ${toks[$i]} "*) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac ;;
      -?*)
        # walk the short cluster char-by-char: a value-opt may sit AFTER valueless flags (ionice -tc 2,
        # /usr/bin/time -ao FILE). The FIRST value-opt char terminates the cluster — if it is the LAST char its
        # value is DETACHED (consume the next token); otherwise the cluster tail is a glued value (this token only).
        rest="${toks[$i]:1}"; i=$((i + 1))
        while [ -n "$rest" ]; do
          first="-${rest:0:1}"; rest="${rest:1}"
          case "$vopts" in *" $first "*) [ -z "$rest" ] && i=$((i + 1)); break ;; esac
        done
        ;;
      *) break ;;
    esac
  done
  while [ "$p" -lt "$npos" ] && [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in -*) break ;; *) i=$((i + 1)); p=$((p + 1)) ;; esac
  done
}

# env's value-options (-u/-C/--unset/--chdir) take a SEPARATE
# value that the blind `*=*|-*) i+=1` skip mis-counts — the walker lands on env's `-C <dir>` argument instead
# of the wrapped command (`env -C . git checkout <ref> -- <floor>` lands on `.` -> ALLOW, rolling the floor
# back past the keystone). ONE shared dynamic-scope helper (toks[]/i/n, the forge_skip_runner model) used by
# ALL FIVE walkers, so a future env-handling fix cannot land in one walker and miss the others. Consumes the
# separate value (i+=2); fail-closes -S/--split-string (it re-parses the rest into a command we cannot verify).
forge_skip_env() {
  local rest first
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      --) i=$((i + 1)); break ;;
      --split-string | --split-string=*) forge_deny "env --split-string restructures the command and cannot be verified — denied" ;;
      --unset | --chdir) i=$((i + 2)) ;;
      --*) i=$((i + 1)) ;;
      -?*)
        # walk the short cluster char-by-char (the forge_skip_runner model): -u/-C may sit AFTER valueless
        # flags (env -iu FOO, env -iC .). The value-opt char terminates the cluster — if it is the LAST char
        # its value is DETACHED (consume next); else the cluster tail is a glued value (this token). -S
        # anywhere in the cluster re-parses the command into args we cannot verify => fail-close.
        rest="${toks[$i]:1}"; i=$((i + 1))
        while [ -n "$rest" ]; do
          first="${rest:0:1}"; rest="${rest:1}"
          case "$first" in
            S) forge_deny "env -S restructures the command and cannot be verified — denied" ;;
            u | C) [ -z "$rest" ] && i=$((i + 1)); break ;;
          esac
        done
        ;;
      *=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
}

# Analyze ONE &&/||/;/|-split segment for a dangerous recursive-force delete.
forge_check_rm_seg() {
  local seg="$1" t flag _o
  local -a toks=()
  _o="$IFS"
  set -f
  IFS=$' \t\n' read -r -a toks <<<"$seg"
  set +f
  IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0

  # Resolve the effective command word: skip leading VAR=val and known runner/wrapper words.
  local i=0
  while [ "$i" -lt "$n" ]; do
    # Strip a glued leading ( or { ; the bare grouping/keyword arm below skips it.
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)) ;;
      *=*) i=$((i + 1)) ;;
      sudo | nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv) forge_skip_runner "${toks[$i]}" ;;
      # Mirror the WRITE walker's exec/busybox skip into the DELETE
      # walker (a write<->delete parity gap — exec/busybox were added to forge_check_mutators_seg
      # but NOT here, so `exec find .git -delete` / `busybox find .beads -delete` / `exec rm`
      # laundered the deleter scan). exec is option-bearing (-a VALUE / -c / -l); a bare -- ends options; an
      # unknown -flag fail-closes. busybox is the +1 multicall wrapper (above).
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      env) forge_skip_env ;;
      xargs)
        # F12 (delete side): resolve ONLY the xargs COMMAND word (M-1-style,
        # mirroring forge_check_mutators_seg) instead of scanning EVERY token — closes `xargs find … -delete`
        # (find launders the deleter scan) AND fixes the pre-existing `xargs grep rm` over-block (a deleter
        # NAME used as an argument). A resolved deleter OR find -> stdin-supplied/unverifiable targets -> deny.
        local k=$((i + 1))
        while [ "$k" -lt "$n" ]; do
          case "${toks[$k]}" in
            -a | -d | -E | -I | -L | -n | -P | -s | --arg-file | --delimiter | --max-lines | --max-args | --max-procs | --max-chars | --replace | --eof) k=$((k + 2)) ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        if [ "$k" -lt "$n" ]; then
          forge_is_deleter "${toks[$k]}" && forge_deny "xargs into a deleter takes stdin-supplied targets (cannot bound to sandbox/) — denied"
          # Deny xargs into find OR a shell/interpreter (a delete can
          # hide in its body) at the PER-SEGMENT level — precise to the resolved command word. This lets the
          # whole-command |xargs gate (below) be relaxed so the daily `find … | xargs grep/cat` READ idiom is
          # no longer wholesale-denied (the over-block), while xargs->rm/find/shell still DENY here.
          case "$(forge_basename "${toks[$k]}")" in
            find) forge_deny "xargs into find (its -delete/-exec reaches unverifiable targets) — denied" ;;
            sh | bash | dash | zsh | ksh | busybox | python | python[0-9.]* | perl | ruby | node) forge_deny "xargs into a shell/interpreter can hide a delete in its body — denied" ;;
          esac
        fi
        return 0
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local cw="${toks[$i]}"

  # Recursive-force "shape": some real -flag carries r/R AND some carries f (long forms count).
  local has_r=0 has_f=0 e=0
  for t in "${toks[@]}"; do
    [ "$e" = 1 ] && break
    case "$t" in
      --) e=1 ;;
      --recursive) has_r=1 ;;
      --force) has_f=1 ;;
      --*) : ;;
      -*) case "$t" in *[rR]*) has_r=1 ;; esac && case "$t" in *f*) has_f=1 ;; esac ;;
    esac
  done
  local shape=0
  { [ "$has_r" = 1 ] && [ "$has_f" = 1 ]; } && shape=1

  # Opaque command identity ($CMD, $(which rm), backticks) in a delete-shaped command → cannot verify.
  case "$cw" in
    *'$'* | *'`'*)
      [ "$shape" = 1 ] && forge_deny "opaque command word in a recursive-force delete cannot be verified ($cw) — split/simplify; denied"
      return 0
      ;;
  esac

  # Unknown wrapper whose immediate next token is a bare deleter (e.g. `runner rm -rf /`) → resolve to it.
  if ! forge_is_deleter "$cw" && [ "$(forge_basename "$cw")" != "find" ]; then
    local nxt="${toks[$((i + 1))]:-}"
    if [ -n "$nxt" ] && forge_is_deleter "$nxt"; then
      i=$((i + 1))
      cw="$nxt"
    fi
  fi

  if forge_is_deleter "$cw"; then
    # Substitution anywhere in a confirmed delete → targets unknowable → deny.
    case "$seg" in *'$('* | *'`'* | *'${'*) forge_deny "delete with a substituted argument cannot be verified — denied" ;; esac
    local base recursive=0 force=0 endopts=0 j=$((i + 1))
    base="$(forge_basename "$cw")"
    local -a targets=()
    while [ "$j" -lt "$n" ]; do
      t="${toks[$j]}"
      j=$((j + 1))
      if [ "$endopts" = 0 ]; then
        case "$t" in
          --) endopts=1 && continue ;;
          --recursive) recursive=1 && continue ;;
          --force) force=1 && continue ;;
          --*) continue ;;
          -*) flag="${t#-}" && { case "$flag" in *[rR]*) recursive=1 ;; esac; case "$flag" in *f*) force=1 ;; esac; } && continue ;;
        esac
      fi
      targets+=("$t")
    done
    # rm is in-scope only when BOTH recursive and force; shred/unlink are always destructive.
    [ "$base" = "rm" ] && { [ "$recursive" = 0 ] || [ "$force" = 0 ]; } && return 0
    [ "${#targets[@]}" -gt 0 ] || forge_deny "recursive/force delete with no resolvable target (cannot bound to sandbox/) — denied"
    for t in "${targets[@]}"; do
      forge_rm_escapes "$t" && forge_deny "recursive delete outside sandbox/ is not allowed (target: $(forge_unquote "$t"))"
    done
    return 0
  fi

  if [ "$(forge_basename "$cw")" = "find" ]; then
    printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-delete([[:space:]]|$)' ||
      printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-exec(dir)?[[:space:]]+[^[:space:]]*(rm|shred|unlink|rmdir)([[:space:]]|$)' ||
      return 0
    case "$seg" in *'$('* | *'`'* | *'${'*) forge_deny "find delete with a substituted root cannot be verified — denied" ;; esac
    local seen=0 j=$((i + 1))
    while [ "$j" -lt "$n" ]; do
      t="${toks[$j]}"
      j=$((j + 1))
      case "$t" in -*) break ;; esac
      seen=1
      forge_rm_escapes "$t" && forge_deny "find delete/exec outside sandbox/ is not allowed (root: $(forge_unquote "$t"))"
    done
    [ "$seen" = 1 ] || forge_deny "find delete/exec without an explicit sandbox/ root — denied"
  fi
  return 0
}

# forge_interp_evalbody <cmd> — the interpreter EVAL-body launder detector, split by family so a
# shell ERREXIT flag is no longer mistaken for an inline eval body. SHELL family (sh/bash/dash/zsh/ksh): the
# eval flag is -c; deny a leading flag-cluster that ENDS in c (-c/-ec) OR that has a c and ends in e (-ce/-cxe).
# A no-c cluster (`bash -e run-task.sh` errexit, `bash -x`, `bash -eu`) runs an argv-VISIBLE script FILE, not
# an inline body -> ALLOW (the errexit relax). SCRIPT family (python/node/perl/ruby): -e is an inline eval body
# and -c is a compile that RUNS BEGIN/use side effects (`perl -c` executes) -> deny c OR e (UNCHANGED from
# before the relax). Replaces the 4 identical inline greps (forge_check_rm / _writes / _push / _bd) with ONE
# definition so the family split cannot drift across the sites (the _intake_fr_hash single-recipe lesson).
# PURE relax: the ONLY verdict flip is a shell no-c errexit cluster (DENY->ALLOW); -ce/-ec eval clusters stay
# DENY and a c-not-terminal `bash -cx` stays as-is (a pre-existing under-block, conceded to the container).
forge_interp_evalbody() {
  local cmd="$1"
  printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(sh|bash|dash|zsh|ksh)[[:space:]]+([^[:space:]]+[[:space:]]+)*(-[A-Za-z]*c([[:space:]]|$)|-[A-Za-z]*c[A-Za-z]*e([[:space:]]|$))' && return 0
  printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(python[0-9.]*|node|nodejs|perl|ruby)[[:space:]]+([^[:space:]]+[[:space:]]+)*-[A-Za-z]*(c|e)([[:space:]]|$)' && return 0
  return 1
}

# Deny recursive-force deletes whose targets escape sandbox/. Fail-closed on anything unparseable.
forge_check_rm() {
  local cmd="$1" seg
  # Delete-adjacent whole-command fail-closed: a pipe into a shell/interpreter, or eval, can hide a
  # delete we cannot inspect. Gated on the command being delete-adjacent (deleter word appears, even
  # quoted) so ordinary pipelines pass.
  if printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_])(rm|shred|unlink|find)([^A-Za-z0-9_]|$)'; then
    printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' && forge_deny "delete via eval cannot be verified — denied"
    # `xargs` is dropped from this whole-command pipe alternation — it
    # wholesale-denied the daily `find … | xargs grep/cat` READ idiom (an over-block that breaks the toolchain).
    # The per-segment forge_check_rm_seg xargs arm now precisely denies xargs->deleter/find/shell while
    # permitting xargs->reader; the |sh/|bash/... interpreter forms below still fail-close the launder.
    printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(sh|bash|dash|zsh|ksh|busybox|python[0-9.]*|node|perl|ruby)([[:space:]]|$)' && forge_deny "delete piped into a shell/interpreter cannot be verified — denied"
    # The interpreter set includes the script-language interpreters (python/node/perl/ruby), whose
    # -c/-e body can hide a deleter the argv walker cannot see. Blocklist-hardening (NOT by-construction):
    # `php -r`, `lua -e` and other un-enumerated interpreters still escape — the OS container is the backstop.
    forge_interp_evalbody "$cmd" && forge_deny "delete inside an interpreter -c/-e body cannot be verified — denied"
  fi
  while IFS= read -r seg; do
    forge_check_rm_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g')"
}

# ---------------- write-target safety (argv-aware; replaces the substring redirect/MUT scan) ----------------
# Resolves the ACTUAL write targets of a command — redirect targets and mutator destinations — and
# denies only writes INTO .git/ (unconditional) or an enforcement path (FORGE_ALLOW_HOOK_EDIT honored,
# logged). Reads are allowed (2>/dev/null, sed -n, cat harness/x, message text mentioning a path).
# FAILS CLOSED on any target it cannot resolve: $VAR / ${..} / $(..) / backtick / glob / ~, fd dups to
# a non-standard descriptor (>&N), process substitution >(..), and mutator dests behind a var or subst.
# Reuses forge_unquote / forge_basename. cp/install/ln judge the LAST operand
# (sources are reads); rm/rmdir/shred/unlink/mv/chmod/chown/truncate judge ALL operands (they remove or
# mutate their operands — mv removes its source, so it cannot be dest-only).

# Path-normalizer (STRUCTURAL): canonicalize the path-NOISE class WHOLESALE —
# collapse repeated slashes (//->/), drop /./ dot-segments (/./ -> /), and strip a trailing /. — so a noise
# variant (`.claude//hooks`, `.claude/./hooks`, `.claude/hooks/.`) cannot defeat the multi-segment enforce
# globs. Supersedes the earlier //-only loop (closes the /./ + trailing-/. class in the same canonical pass,
# so the floor does not chase one slash-form per round). `..` is NOT resolved here — textual `..` resolution
# is UNSAFE (a symlinked segment makes `a/..` diverge from the textual parent: `sandbox/link/../hooks` could
# FS-resolve INTO the floor while textually resolving in-bounds). So `..` stays FAIL-CLOSED at the */../*
# ambiguous arm below (strictly safer than resolving). Pure-textual, no FS/symlink touch (container's job).
forge_norm_path() {
  local p="$1"
  while case "$p" in *//*) true ;; *) false ;; esac; do p="${p//\/\//\/}"; done
  while case "$p" in */./*) true ;; *) false ;; esac; do p="${p//\/.\//\/}"; done
  case "$p" in */.) p="${p%/.}" ;; esac
  printf '%s' "$p"
}

# Classify a RESOLVED write target: git | beads | enforce | ambiguous | ok.
# Tier-unification: the SHARED enforce-dir classifier — given an already-
# NORMALIZED path, return git | beads | enforce | ok via the bare-dir + child + nested arms. BOTH tiers use
# THIS — the BASH tier via forge_path_class below, the FILE_PATH/Write-Edit tier in pre-tool-use-deny.sh — so
# they CANNOT DIVERGE on the enforce SET (the cross-tier divergence class — normalization, bare-dir +
# ..-parity — is closed structurally, one classifier instead of two that drift). Each tier wraps it with its
# OWN input-validation: the shell tier (forge_path_class) treats glob/$/~ as AMBIGUOUS (shell metachars); the
# file_path tier treats them as LITERAL filename chars (e.g. Next.js app/[id]/page.tsx) and fail-closes only
# on `..` — that per-tier difference is CORRECT (different input semantics), so it is deliberately NOT shared.
forge_enforce_class() {
  local q="${1#./}"
  case "$q" in .git | .git/*) printf 'git'; return ;; esac
  case "/$q" in */.git | */.git/*) printf 'git'; return ;; esac
  # .beads/ ledger: bd-managed; raw Bash writes (mutators/redirects) denied. bd itself isn't a mutator verb.
  case "$q" in .beads | .beads/*) printf 'beads'; return ;; esac
  case "/$q" in */.beads | */.beads/*) printf 'beads'; return ;; esac
  case "$q" in
    # F1: .claude/hooks needs the BARE-dir arm (.git/.beads/harness/.harness
    # all carry bare+child) — without it `mv /tmp/lib.sh .claude/hooks` drops the file INTO the hooks dir and
    # was classified 'ok'. The bare arm is an EXACT literal (no glob), so `.claude/hooksX` / `.claude/hooks-backup`
    # do NOT false-match; trailing-slash and child forms hit `.claude/hooks/*`; `./` is normalized off into $q.
    .claude/hooks | .claude/hooks/* | harness | harness/* | .harness | .harness/* | .claude/settings.json | .claude/settings.local.json) printf 'enforce'; return ;;
  esac
  case "/$q" in
    # F10: nested-bare harness/.harness (the real dirs sit at the repo root,
    # so their ABS path is a nested-bare form — `cp /tmp/x <abs>/harness` slipped). Mirrors */.git, */.beads,
    # */.claude/hooks which all carry bare+child here.
    */.claude/hooks | */.claude/hooks/* | */harness | */harness/* | */.harness | */.harness/* | */.claude/settings.json | */.claude/settings.local.json) printf 'enforce'; return ;;
  esac
  printf 'ok'
}

# Classify a RESOLVED write target (SHELL-argv semantics): git | beads | enforce | ambiguous | ok.
forge_path_class() {
  local p
  p="$(forge_norm_path "$(forge_unquote "$1")")"
  case "$p" in '' | *'$'* | *'`'* | *'*'* | *'?'* | *'['* | '~'*) printf 'ambiguous'; return ;; esac
  case "/$p/" in */../*) printf 'ambiguous'; return ;; esac
  forge_enforce_class "$p"
}

# Dispatch a resolved target to the correct verdict. .git/ + .beads/ = unconditional; enforce = door-gated.
forge_classify_target() {
  case "$(forge_path_class "$1")" in
    git) forge_deny "writing under .git/ is not allowed (target: $(forge_unquote "$1"))" ;;
    beads) forge_deny "the .beads/ ledger is bd-managed — mutate via bd, never a raw edit (target: $(forge_unquote "$1"))" ;;
    enforce)
      if [ "${ALLOW_HOOK_EDIT:-0}" = "1" ]; then
        forge_log_bypass "write-target: $(forge_unquote "$1")"
      else
        forge_deny "writing into an enforcement/harness path is not allowed (target: $(forge_unquote "$1")); set FORGE_ALLOW_HOOK_EDIT=1 for supervised maintenance"
      fi
      ;;
    ambiguous) forge_deny "write target cannot be resolved (variable/substitution/glob/..) — make it explicit; denied" ;;
    ok) : ;;
  esac
}

# If a token is a WRITE redirect, echo: NEXT (target is the next token) | PROCSUB | FD:<m> | <attached
# target>. Empty for non-write tokens (plain words, input redirects).
forge_redir_target() {
  local t="$1" _d
  case "$t" in
    *'>('*) printf 'PROCSUB'; return ;;
    *'>&'*) printf 'FD:%s' "${t##*>&}"; return ;;
  esac
  # Peel a LEADING fd digit-RUN (1+ digits) when followed by a write operator, so a
  # MULTI-digit fd (`12>file`) is classified like a single-digit one — the arms below match only [0-9]
  # (single), so `echo x 12> .git/config` slipped past the walker (a forge-own-path hole). `<>` is a WRITE
  # (O_RDWR|O_CREAT creates the target). A digit run not followed by a write op is a plain word / input
  # redirect -> left intact -> non-write. n=1 is the unchanged single-digit case.
  case "$t" in
    [0-9]*) _d="${t%%[!0-9]*}"; case "${t#"$_d"}" in '>'* | '>>'* | '>|'* | '<>'*) t="${t#"$_d"}" ;; esac ;;
  esac
  case "$t" in
    '&>>' | '&>' | '>>' | '>|' | '>' | '<>') printf 'NEXT'; return ;;
    '&>>'*) printf '%s' "${t#&>>}"; return ;;
    '&>'*) printf '%s' "${t#&>}"; return ;;
    '<>'*) printf '%s' "${t#<>}"; return ;;
    '>>'*) printf '%s' "${t#>>}"; return ;;
    '>|'*) printf '%s' "${t#>|}"; return ;;
    '>'*) printf '%s' "${t#>}"; return ;;
  esac
  printf ''
}

# Scan the WHOLE command for write-redirect targets — command-wide, so `>|` and redirects that span a
# pipe are not broken by the &&/||/;/| segment splitter.
forge_check_redirects() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    forge_check_redirects_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/>\|/\x05/g; s/&>>/\x01/g; s/&>/\x02/g; s/>&/\x03/g; s/<&/\x04/g; s/(\&\&|\|\||\|&|;|\|)/\n/g; s/&/\n/g; s/\x05/>|/g; s/\x04/<\&/g; s/\x03/>\&/g; s/\x02/\&>/g; s/\x01/\&>>/g')"
}

forge_check_redirects_seg() {
  local seg="$1" r m _o k
  local -a toks=()
  _o="$IFS"; set -f; IFS=$' \t\n' read -r -a toks <<<"$seg"; set +f; IFS="$_o"
  local n="${#toks[@]}"
  for ((k = 0; k < n; k++)); do
    r="$(forge_redir_target "${toks[$k]}")"
    [ -z "$r" ] && continue
    case "$r" in
      PROCSUB) forge_deny "redirect into a process substitution cannot be verified — denied" ;;
      FD:0 | FD:1 | FD:2 | FD:-) : ;;
      FD:*) forge_deny "fd redirect to a non-standard descriptor (provenance unknown) — denied" ;;
      NEXT) m="${toks[$((k + 1))]:-}"; [ -n "$m" ] && forge_classify_target "$m" ;;
      *) forge_classify_target "$r" ;;
    esac
  done
}

# Resolve mutator destinations in ONE &&/||/;/|-split segment.
# Floor-hardening: this walker is recognized-writer defense-in-depth. The textual floor CANNOT separate
# an exotic writer from an exotic reader by argv alone, so the unrecognized-COMMAND space is the OS
# container's job; for the writers it recognizes it is target-position-correct + complete:
#   - relocatable cp/mv/install/ln: dest is the LAST operand UNLESS -t/--target-directory relocates it
#     (the C1 class — a target-relocating flag laundering the dest past the last-operand assumption).
#   - all-operand rm/.../touch/mkdir: every non-flag operand (minus value-flag VALUES) is a target.
#   - rsync: dest is the LAST operand (sources are reads). dd of=, sed -i: unchanged.
#   - in-place editors (perl/ruby/gawk/awk -i), line editors (ed/ex), archive WRITERS (tar create/extract,
#     cpio): write targets are not safely argv-separable -> FAIL CLOSED. tar/cpio list/read modes pass.
# tests/escape-classes pins this set RED-first and GROWS when a new bypass class is found.
forge_check_mutators_seg() {
  local seg="$1" t r _o
  local -a toks=()
  _o="$IFS"; set -f; IFS=$' \t\n' read -r -a toks <<<"$seg"; set +f; IFS="$_o"
  local n="${#toks[@]}"; [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0

  local i=0 bw
  while [ "$i" -lt "$n" ]; do
    # *=* is matched on the RAW token (a VAR=val prefix); basenaming it would drop the '=' for VAR=/p/q.
    case "${toks[$i]}" in *=*) i=$((i + 1)); continue ;; esac
    # A leading shell grouping-open or reserved word is NOT the command word —
    # it prefixes the real command. Strip a GLUED ( or { (so '(cp' -> 'cp'), then skip a BARE grouping/keyword
    # token. Otherwise the walker resolves the command word to (/{/then/do/... and silently permits the writer
    # it fronts: '( cp x <floor> )', '{ mv x <floor>; }', 'for f in a; do cp x <floor>; done'. Grouping tokens
    # and reserved words are never a command name or a path (type -t = keyword/none), so the skip cannot over-block.
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)); continue ;; esac
    # C-4: match the BASENAME (like the xargs arm already does), so a
    # path-qualified / quoted / backslash-escaped wrapper (/usr/bin/env, "sudo", \exec) is still skipped to
    # the writer it fronts — not mis-resolved to an unrecognized command word and silently permitted.
    # exec + busybox are MULTICALL wrappers (they re-dispatch the next arg); docker/apt/npm/git are
    # tools-with-SUBCOMMANDS, NOT wrappers, so they stay OFF this list (else apt install / docker cp / git mv
    # false-DENY). A novel multicall wrapper (toybox) escapes until added here (the C1 meta-lesson).
    bw="$(forge_basename "${toks[$i]}")"
    case "$bw" in
      sudo | nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv) forge_skip_runner "${toks[$i]}" ;;
      # C-5: exec is option-bearing — `-a NAME` takes a value; `-c`/`-l` do
      # not. Consume them so `exec -a foo cp <t>` resolves to cp; any OTHER -flag is unknown -> fail closed
      # (exec has no other options; the blind +1 was the incomplete half of the earlier exec addition).
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      # H-1: env's -u/--unset and -C/--chdir take a SEPARATE value the old arm
      # mis-skipped (it broke on the value, mis-resolving it as the command word). -S/--split-string
      # restructures argv into a command (opaque) -> fail closed. Other -flags and *=* assignments advance one.
      env) forge_skip_env ;;
      # M-1: resolve ONLY the xargs COMMAND word (skip xargs's own options +
      # their values), then basename-match THAT. Scanning EVERY token false-DENYs a writer NAME used as an
      # argument (`xargs grep -l mkfifo`) — the over-block the widened denylist in hunk (c) introduced.
      xargs)
        local kk=$((i + 1))
        while [ "$kk" -lt "$n" ]; do
          case "${toks[$kk]}" in
            -a | -d | -E | -I | -L | -n | -P | -s | --arg-file | --delimiter | --max-lines | --max-args | --max-procs | --max-chars | --replace | --eof) kk=$((kk + 2)) ;;
            -*) kk=$((kk + 1)) ;;
            *) break ;;
          esac
        done
        if [ "$kk" -lt "$n" ]; then
          case "$(forge_basename "${toks[$kk]}")" in
            rm | rmdir | shred | unlink | mv | cp | install | tee | dd | truncate | ln | chmod | chown | sed | touch | mkdir | rsync | tar | cpio | ed | ex | mkfifo | mknod | link) forge_deny "xargs into a mutator has stdin-supplied targets — denied" ;;
            # F12: xargs FRONTING find launders the entire find arm — the
            # M-1 resolution lands on `find` (not a recognized mutator) and returns before the find -exec
            # check ever runs (`xargs find .claude/hooks -exec sed -i {}` rewrote the floor). xargs-fronting-
            # find is exotic + its -exec/-delete targets are argv-unverifiable -> fail closed.
            find) forge_deny "xargs into find (its -exec/-delete reaches argv-unverifiable targets) — denied" ;;
          esac
        fi
        return 0
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local base
  base="$(forge_basename "${toks[$i]}")"
  # C-1: a CONFIRMED recognized-writer segment carrying command-substitution
  # ($()/backtick/${}) cannot have its targets statically verified -> fail closed. Mirrors forge_check_rm_seg
  # and forge_check_push_seg. GATED on a confirmed writer base, so non-writer commands with substitution
  # (node $(which x), VAR=$(...), echo $(date)) are NOT newly over-blocked.
  # F4: the writer set lists ONLY the ALWAYS-writers (every operand IS a
  # write target). The multi-mode text tools (sed/perl/ruby/gawk/awk/ed/ex/cpio/tar) are DROPPED — they
  # over-blocked READ-mode invocations carrying $() (awk '{print}' $(cat x), tar tf $(...), sed -n $(...)).
  # No under-block is traded away: each dropped tool's WRITE case is already fail-closed by its OWN handler
  # regardless of substitution — sed -i via the sed dispatch (classifies the file operand); perl/ruby/gawk/awk
  # -i + ed/ex + cpio + tar-write-mode via the exotic block below; a substituted dest is caught by the
  # ambiguous arm in forge_path_class. (Proven by the F4 under-block battery cases.)
  case "$base" in
    rm | rmdir | shred | unlink | mv | cp | install | ln | rsync | link | chmod | chown | truncate | touch | mkdir | tee | mkfifo | mknod | dd)
      case "$seg" in *'$('* | *'`'* | *'${'*) forge_deny "a write/mutate with a substituted argument cannot be verified — denied" ;; esac ;;
  esac
  # F7: an OPAQUE command word ($()/backtick/${}) near an enforcement/.git/
  # .beads path cannot be confirmed NOT to be a writer to that path -> fail closed (mirrors forge_check_rm_seg
  # and forge_check_push_seg, which fail-close an opaque command word in a delete-shaped / push segment —
  # completing write-path parity). GATED on a cardinal path appearing
  # in the segment, so an opaque command word in an ordinary command (node $(which x), echo $(date)) is NOT
  # over-blocked (the design leaves the unrecognized-command space to the OS container at the work-root
  # tier). toks[i] is the resolved command VERB (a $()-bearing VAR= prefix was skipped by the *=* arm).
  case "${toks[$i]}" in
    *'$('* | *'`'* | *'${'*)
      # F9: iterate forge_path_class over the OPERANDS instead of a
      # hand-rolled path regex. The earlier regex required a trailing slash for .git/.beads/harness/.harness, so a
      # BARE protected dir (`$(printf cp) /tmp/x harness`) slipped; and a slash-less form risked a `.gitignore`
      # false-positive. Reusing the classifier is precise AND inherits the F1/F10/F11 hardening (bare-dir,
      # nested-bare, doubled-slash) for free.
      local fj
      for ((fj = i + 1; fj < n; fj++)); do
        case "$(forge_path_class "${toks[$fj]}")" in
          git | beads | enforce) forge_deny "an opaque command word near an enforcement path cannot be verified — denied (cp-floorhardening)" ;;
        esac
      done ;;
  esac

  # Exotic writers whose write targets are not safely argv-separable -> fail closed (deny the unverifiable;
  # the agent uses a recognized writer or runs under the OS container). Read/list modes pass.
  case "$base" in
    perl | ruby)
      # Comprehensive in-place enumeration (supersedes the switch-only check): the in-place
      # switch i can be CLUSTERED with other single-char switches (`-pi` == -p -i, `-ni`, `-wpi`, `-pi.bak`).
      # SCAN the leading single-dash cluster char-by-char honoring per-switch arity: i -> in-place;
      # -0 consumes ONLY trailing OCTAL digits (so `-0777pi` keeps scanning past the octal and finds the i —
      # fixing the bug that let -0 swallow the rest); a VALUE-TAKER [eEIMmFCr] (-e/-E prog, -I dir,
      # -M/-m module, -F pat, -C unicode/dir, -r require) consumes the rest as its value -> stop (so a value
      # containing i — -I/path/with/i, -Mstrict, -ri18n, -Cdir — is NOT a false in-place); any other char is a
      # flag, keep scanning. Long forms --inplace/--in-place[=] handled directly. Read-mode (-ne/-pe) -> no i.
      local jj ipe=0 cl
      for ((jj = i + 1; jj < n; jj++)); do
        case "${toks[$jj]}" in
          --inplace | --in-place | --in-place=*) ipe=1 ;;
          --*) : ;;
          -*)
            cl="${toks[$jj]#-}"
            while [ -n "$cl" ]; do
              case "$cl" in
                i*) ipe=1; break ;;
                0*) cl="${cl#0}"; while case "$cl" in [0-7]*) true ;; *) false ;; esac; do cl="${cl#?}"; done ;;
                [eEIMmFCr]*) break ;;
                *) cl="${cl#?}" ;;
              esac
            done ;;
        esac
      done
      [ "$ipe" = 1 ] && forge_deny "in-place edit via $base cannot be argv-verified for its file targets — denied (cp-floorhardening; use a recognized writer or the OS container)"
      return 0 ;;
    gawk | awk)
      # Comprehensive in-place enumeration: gawk/awk in-place loads the
      # `inplace` EXTENSION via -i/-l/--include/--load (NOT a clustered i like perl). Detect the `inplace`
      # token in ALL its surface forms: a SEPARATE value (-i inplace / -l inplace / --include inplace /
      # --load inplace -> the bare `inplace` token), ATTACHED (-iinplace / -linplace), and =-ATTACHED
      # (--include=inplace / --load=inplace — a gap an earlier pass left). A NON-inplace include/load
      # (--include=foolib, -i mylib.awk) -> no match -> ALLOW (read). find -exec gawk =-form is caught by NAME.
      local jj ipe=0
      for ((jj = i + 1; jj < n; jj++)); do
        case "${toks[$jj]}" in
          inplace) ipe=1 ;;
          -i* | -l*) case "${toks[$jj]}" in *inplace*) ipe=1 ;; esac ;;
          --include=*inplace* | --load=*inplace* | --in-place | --in-place=*) ipe=1 ;;
        esac
      done
      [ "$ipe" = 1 ] && forge_deny "in-place edit via $base cannot be argv-verified for its file targets — denied (cp-floorhardening; use a recognized writer or the OS container)"
      return 0 ;;
    # COMPREHENSIVE editor-writer class (the close-the-class lesson,
    # not one editor per round). The vi family + emacs support NON-INTERACTIVE scripted writes to an argv
    # operand (vim -es -c wq FILE, vim -c :wq FILE, nvim -es ..., emacs --batch FILE -f save-buffer) — the same
    # write the already-recognized ed/ex do; their target is argv-VISIBLE so this is NOT program-internal.
    # Mode-agnostic deny (consistent with ed/ex): bare interactive `vim FILE` blocks on a TTY the agent lacks.
    # Fires only when the editor is the COMMAND word (grep vim / cp vim.txt are unaffected — they are arguments).
    ed | red | ex | vi | vim | view | rvim | rview | nvim | gvim | vimdiff | emacs | emacsclient)
      forge_deny "$base is a file editor whose write target is not argv-verifiable — denied (cp-floorhardening; use a recognized writer or the OS container)" ;;
    cpio)
      forge_deny "cpio write targets are not argv-verifiable — denied (cp-floorhardening; use a recognized writer or the OS container)" ;;
    tar)
      local jj wr=0
      for ((jj = i + 1; jj < n; jj++)); do
        case "${toks[$jj]}" in
          --extract | --get | --create | --append | --update | --catenate | --concatenate | --delete) wr=1 ;;
          --*) : ;;
          -*) case "${toks[$jj]}" in *[xcruA]*) wr=1 ;; esac ;;
          [xcruA]*) wr=1 ;;
        esac
      done
      [ "$wr" = 1 ] && forge_deny "tar in a write mode (create/extract/append) cannot be argv-verified for its targets — denied (cp-floorhardening; use a recognized writer or the OS container)"
      return 0 ;;
    patch)
      # patch: `patch ORIGFILE [PATCHFILE]` / `patch ORIGFILE < diff` /
      # `patch -o OUT …` names the WRITE target argv-visibly -> classify it (the explicit-operand cardinal-edit
      # `patch .claude/hooks/lib.sh` closes). `patch -pN < diff` / `patch -i DIFF` (no explicit ORIGFILE) takes
      # its targets from INSIDE the diff (program-internal, argv-invisible) -> fail closed — the OS container's
      # job. -i/--input CONSUMES the patchfile value so it is not mistaken for the ORIGFILE.
      local jj pfirst="" pout="" rr
      for ((jj = i + 1; jj < n; jj++)); do
        # Skip redirect tokens so a read-redirect (`< diff`, the stdin-diff form) is NOT mis-collected as the
        # explicit ORIGFILE (write-redirect targets are classified by forge_check_redirects already).
        rr="$(forge_redir_target "${toks[$jj]}")"
        if [ -n "$rr" ]; then case "$rr" in NEXT) jj=$((jj + 1)) ;; esac; continue; fi
        case "${toks[$jj]}" in
          '<' | [0-9]'<') jj=$((jj + 1)); continue ;;
          '<'* | [0-9]'<'*) continue ;;
          -o | --output) jj=$((jj + 1)); pout="${toks[$jj]:-}" ;;
          --output=*) pout="${toks[$jj]#--output=}" ;;
          -o?*) pout="${toks[$jj]#-o}" ;;
          -i | --input) jj=$((jj + 1)) ;;
          --input=*) : ;;
          --*) : ;;
          -*) : ;;
          *) [ -z "$pfirst" ] && pfirst="${toks[$jj]}" ;;
        esac
      done
      [ -n "$pout" ] && forge_classify_target "$pout"
      if [ -n "$pfirst" ]; then
        forge_classify_target "$pfirst"
      else
        forge_deny "patch with no explicit ORIGFILE applies a stdin/-i diff to program-internal targets — not argv-verifiable, denied (cp-floorhardening; use a recognized writer or the OS container)"
      fi
      return 0 ;;
  esac

  # C-2: find -exec <writer> / -execdir <writer> writes to the MATCHED files
  # (not an argv-visible dest), so its targets cannot be bounded -> fail closed. Mirrors forge_check_rm_seg's
  # find arm. F3: the writer set is now the FULL segment-walker writer set —
  # cp|mv|install|ln|rsync|tee|dd|truncate|mkfifo|mknod|link|sed PLUS the exotic/multi-mode writers
  # rsync|gawk|awk|ed|ex|cpio|tar (the direct path fail-closes these via the exotic block, so find -exec must
  # too; perl|ruby are in the interpreter arm below). The earlier set OMITTED gawk/awk/rsync/ed/ex/cpio/tar,
  # so `find .claude/hooks -exec gawk -i inplace {} ;` was a one-step floor-disable while the direct gawk -i
  # was caught. chmod/chown are DELIBERATELY EXCLUDED — `find … -exec chmod 644 {} +` is common + the
  # over-block class. -exec into an interpreter (sh/bash/env/python…) is laundering -> fail closed. find's OWN write
  # actions (-fprintf/-fprint/-fls FILE) over an unbounded matched set -> fail closed. find -exec on a READER
  # (grep/cat/ls/wc) has no writer in the set -> permitted. (find-exec-writer fails closed regardless of root
  # because -exec's dest is unverifiable — a documented asymmetry vs the delete path.)
  if [ "$base" = find ]; then
    printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-exec(dir)?[[:space:]]+[^[:space:]]*(cp|mv|install|ln|rsync|tee|dd|truncate|mkfifo|mknod|link|sed|gawk|awk|ed|red|ex|vi|vim|view|rvim|rview|nvim|gvim|vimdiff|emacs|emacsclient|cpio|tar)([[:space:]]|$)' &&
      forge_deny "find -exec <writer> cannot be argv-verified for its targets — denied (cp-floorhardening; use a recognized writer or the OS container)"
    printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-exec(dir)?[[:space:]]+[^[:space:]]*(sh|bash|dash|zsh|ksh|busybox|env|python[0-9.]*|perl|ruby|node)([[:space:]]|$)' &&
      forge_deny "find -exec into an interpreter cannot be verified — denied (cp-floorhardening)"
    printf '%s' "$seg" | grep -Eq -- '(^|[[:space:]])-(fprintf|fprint|fprint0|fls)([[:space:]]|$)' &&
      forge_deny "find -fprintf/-fprint/-fls writes a file over an unbounded matched set — denied (cp-floorhardening)"
    return 0
  fi

  # Operand collection. For cp/mv/install/ln a -t/--target-directory relocates the dest off the last
  # operand (the C1 class) — capture it. Benign unmodeled flags are skipped so the real positional dest is
  # still classified (no over-block). touch/mkdir value-flag VALUES (-r/-t/-d ref/stamp/date, -m mode) are
  # reads/non-targets, not write destinations.
  local -a ops=(); local endo=0 j reloc="" reloc_seen=0 reloc_verb=0 instd=0 sed_e_seen=0
  case "$base" in cp | mv | install | ln) reloc_verb=1 ;; esac
  for ((j = i + 1; j < n; j++)); do
    t="${toks[$j]}"
    r="$(forge_redir_target "$t")"
    if [ -n "$r" ]; then case "$r" in NEXT) j=$((j + 1)) ;; esac; continue; fi
    # Redirects name a stream, not a positional write target. PURE-READ redirects (< , N< , and attached
    # <src / N<src) are skipped HERE, AFTER the write-redirect check above (so >,>>,>|,&>,N> targets are
    # still classified) — the separated form also consumes the following source token. But read-WRITE
    # redirects (<> , N<>) open the named file on an fd the writer MAY write to (1<> puts it on stdout,
    # which tee copies stdin into — a real out-of-root write) and the write-redirect tier returns EMPTY
    # for them, so they are NOT safe to skip: fall through (`:`) so the target is classified -> fail-closed.
    case "$t" in
      '<>' | [0-9]'<>' | '<>'* | [0-9]'<>'*) : ;;
      '<' | [0-9]'<') j=$((j + 1)); continue ;;
      '<'* | [0-9]'<'*) continue ;;
    esac
    if [ "$endo" = 0 ]; then
      case "$t" in --) endo=1; continue ;; esac
      if [ "$reloc_verb" = 1 ]; then
        # cp/mv/install/ln: --target-directory is the ONLY --t… long flag, so any GNU abbreviation
        # (--t, --ta, … --target-directory[=DIR]) relocates the dest. Match the abbreviation class, not
        # just the full spelling (the --targ= under-block). Short -t / -tDIR / clustered -…t likewise.
        # Test the ATTACHED arm (-*t?* — a t with >=1 char after, so the dir is IN the
        # token) BEFORE the bare/clustered suffix arm (-*t — dir is the NEXT token). The inverted order let
        # `-t/out` (a dir ENDING in t) match the suffix arm and swallow the next operand, leaking the real
        # /out (the attached-relocator escape). Mirrors the --t*= before --t* long side.
        case "$t" in
          --t*=*) reloc_seen=1; reloc="${t#*=}"; continue ;;
          --t*) reloc_seen=1; reloc="${toks[$((j + 1))]:-}"; j=$((j + 1)); continue ;;
          --*) : ;;
          -*t?*) reloc_seen=1; reloc="${t#*t}"; continue ;;
          -*t) reloc_seen=1; reloc="${toks[$((j + 1))]:-}"; j=$((j + 1)); continue ;;
        esac
      fi
      if [ "$base" = touch ]; then
        case "$t" in -r | -t | -d | --reference | --time | --date) j=$((j + 1)); continue ;; --reference=* | --time=* | --date=*) continue ;; esac
      fi
      if [ "$base" = mkdir ] || [ "$base" = mkfifo ] || [ "$base" = mknod ]; then
        case "$t" in -m | --mode) j=$((j + 1)); continue ;; --mode=*) continue ;; esac
      fi
      if [ "$base" = sed ]; then
        # -e SCRIPT / -f FILE: the VALUE is a script (text) or a script FILE sed READS — never a write
        # target. Consume it and record that a non-positional script was given, so the dispatch knows
        # there is NO bare-script operand to skip (every positional operand is then a file to rewrite).
        case "$t" in
          -e | -f | --expression | --file) sed_e_seen=1; j=$((j + 1)); continue ;;
          --expression=* | --file=* | -e?* | -f?*) sed_e_seen=1; continue ;;
        esac
      fi
      case "$t" in -d) [ "$base" = install ] && instd=1 ;; esac
      case "$t" in -*) continue ;; esac
    fi
    ops+=("$t")
  done
  local nops="${#ops[@]}"

  # A target-relocating flag was given -> THAT dir is the dest; positional operands are sources/reads.
  if [ "$reloc_seen" = 1 ]; then
    forge_classify_target "$reloc"
    return 0
  fi

  case "$base" in
    rm | rmdir | shred | unlink | mv | chmod | chown | truncate | touch | mkdir | tee | mkfifo)
      [ "$nops" -gt 0 ] && for t in "${ops[@]}"; do forge_classify_target "$t"; done ;;
    install)
      if [ "$instd" = 1 ]; then
        [ "$nops" -gt 0 ] && for t in "${ops[@]}"; do forge_classify_target "$t"; done
      else
        [ "$nops" -gt 0 ] && forge_classify_target "${ops[$((nops - 1))]}"
      fi ;;
    cp | ln | rsync | link)
      [ "$nops" -gt 0 ] && forge_classify_target "${ops[$((nops - 1))]}" ;;
    mknod)
      # mknod NAME TYPE [MAJOR MINOR]: only NAME (first operand) is a created path; TYPE (b/c/p/u) and
      # MAJOR/MINOR are not paths -> classify ops[0] only (all-operand would over-block the type/numbers).
      [ "$nops" -gt 0 ] && forge_classify_target "${ops[0]}" ;;
    dd)
      [ "$nops" -gt 0 ] && for t in "${ops[@]}"; do case "$t" in of=*) forge_classify_target "${t#of=}" ;; esac; done ;;
    sed)
      # In-place ONLY: -i / -i<suffix> (e.g. -i.bak) / clustered single-dash -…i… / --in-place[=…]. A sed
      # WITHOUT in-place is a READER (writes to stdout) — classify nothing, so it never over-blocks a read
      # of an out-of-root file. Long options other than --in-place never imply in-place (so --file,
      # --expression, --quiet … — which contain an 'i' — are not mistaken for it; only single-dash -…i…).
      local inplace=0
      for ((j = i + 1; j < n; j++)); do
        case "${toks[$j]}" in
          --in-place | --in-place=*) inplace=1 ;;
          --*) : ;;
          -*i*) inplace=1 ;;
        esac
      done
      if [ "$inplace" = 1 ] && [ "$nops" -gt 0 ]; then
        if [ "$sed_e_seen" = 1 ]; then
          # script came via -e/-f -> EVERY positional operand is a file to rewrite.
          for t in "${ops[@]}"; do forge_classify_target "$t"; done
        else
          # bare-script form `sed -i 'PROG' FILE…` -> ops[0] is the PROG (not a path); FILEs are ops[1..].
          local kf
          for ((kf = 1; kf < nops; kf++)); do forge_classify_target "${ops[$kf]}"; done
        fi
      fi ;;
  esac
  return 0
}

# Deny writes/mutations into .git/ or enforcement paths; fail-closed on anything unresolvable.
forge_check_writes() {
  local cmd="$1" seg
  # F2: \.beads/ added to the launder-gate alternation. The pipe-into-shell,
  # eval, and the NEW H-2 interpreter -c-body guards below ALL gate on this regex; it previously omitted the
  # bd-managed ledger, so `bash -c 'sed -i .beads/issues.jsonl'` (and the eval/pipe forms) laundered into
  # .beads while the identical .git/.claude/hooks forms denied. Zero over-block: .beads direct writes already
  # deny unconditionally (forge_path_class), so a benign .beads command not matching pipe/eval/-c still passes.
  # Collapse /./ and // in a COPY of the command for the launder-GATE check
  # only, so the compounded `bash -c 'sed -i .claude/./hooks/lib.sh'` (path-noise + interpreter-c) is caught —
  # the gate fires on the canonical path and the -c guard below denies. gcmd is used ONLY
  # for this path-presence gate; the pipe/eval/-c sub-checks read $cmd (they detect the interpreter, not paths).
  local gcmd="$cmd"
  while case "$gcmd" in *//*) true ;; *) false ;; esac; do gcmd="${gcmd//\/\//\/}"; done
  while case "$gcmd" in */./*) true ;; *) false ;; esac; do gcmd="${gcmd//\/.\//\/}"; done
  # Left-context is (^|[^A-Za-z0-9_.-]) — admits '=' (and any non-path
  # byte) so a KEY=PATH writer GLUED to '=' (dd of=<floor>, tar -cf=<floor>) is detected, closing the launder
  # where the path rides an '=' and the eval/pipe/-c sub-checks were being skipped. EXCLUDES alnum/./- from the
  # trigger so sibling names (myharness/, x.harness, .harnessX, a.beadsX) do NOT false-fire.
  # F1 (gate side): each floor-DIR alternative is now bare-OR-child via a right-boundary
  # (/|$|[^A-Za-z0-9_-]) — was slash-terminated, so a write to a BARE floor dir (bash -c 'cp x .claude/hooks')
  # missed the gate and the pipe/eval/-c sub-checks never ran (the LAST surface of the bare-dir class — the
  # classifier got it in F1, the gate didn't; parity with the verb-keyed DELETE gate which already catches
  # `bash -c 'rm -rf .claude/hooks'`). The right-boundary keeps siblings safe (.gitignore / .claude/hooksX /
  # harness-utils ALLOW — alnum/_/- excluded) while bare ($) + child (/) + .json (.) DENY. The intentionally-
  # loose .claude/settings alternative (a prefix matching settings.json / settings.local.json) is left as-is.
  # Over-fire here is harmless — it only triggers MORE -c-body inspection; the sub-checks below gate the deny.
  if printf '%s' "$gcmd" | grep -Eq '(^|[^A-Za-z0-9_.-])((\.git|\.beads|\.claude/hooks|harness|\.harness)(/|$|[^A-Za-z0-9_-])|\.claude/settings)'; then
    printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(sh|bash|dash|zsh|ksh|busybox|xargs|python[0-9.]*|node|perl|ruby)([[:space:]]|$)' && forge_deny "enforcement-adjacent command piped into a shell/interpreter cannot be verified — denied"
    printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' && forge_deny "enforcement-adjacent eval cannot be verified — denied"
    # H-2: mirror forge_check_rm — an enforcement-adjacent interpreter -c body
    # can hide a writer the argv walker cannot see (bash -c 'sed -i <hook>'). GATED on an enforcement path
    # appearing (cardinal scope), so a benign `sh -c` elsewhere is NOT over-blocked. `xargs` was added to the
    # pipe alternation above (parity with forge_check_rm) so `… <hook> | xargs sed -i` is caught too.
    # The interpreter set includes python/node/perl/ruby, whose -c/-e body can hide a writer the argv
    # walker cannot see (python3 -c "open('.claude/hooks/lib.sh','w')…"). STILL GATED on an enforcement path
    # appearing above, so a benign `python3 -c 'print(1)'` is NOT over-blocked. Blocklist-hardening (NOT by-
    # construction): `php -r`, `lua -e` and other un-enumerated interpreters still escape — the container backstops.
    forge_interp_evalbody "$cmd" && forge_deny "enforcement-adjacent interpreter -c/-e body cannot be verified — denied"
  fi
  forge_check_redirects "$cmd"
  # C-3 + F6: split on the background/sequencing `&` in ADDITION to
  # && || ; | — else a trailing `&` becomes a phantom last operand (`cp src /out &` -> the walker classifies
  # `&`, leaking /out) and a separator `&` hides the writer after it (`foo & cp src /out`, no-space `foo&cp`).
  # The earlier space-delimited patterns MISSED the no-space form (`echo hi&cp <hook>`). Robust approach:
  # convert && || ; | first; PROTECT the redirect forms &>>/&>/>& (placeholders \x01-\x03) so they are not
  # split; convert EVERY remaining `&` (all now command separators) to a newline; restore the redirects.
  # Leaves &&, &>, &>>, >& and 2>&1 intact; splits spaced, no-space, multiple, and trailing separators.
  while IFS= read -r seg; do
    forge_check_mutators_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g; s/&>>/\x01/g; s/&>/\x02/g; s/>&/\x03/g; s/&/\n/g; s/\x03/>\&/g; s/\x02/\&>/g; s/\x01/\&>>/g')"
}
# ---------------- push-to-main safety (argv-aware, per-segment; replaces the whole-command scan) #7 ----------------
# Scopes force/mirror/refspec checks to the push invocation's OWN argv, so a sibling `gh pr create
# --base main`, `git log --all`, `echo --force`, or `echo "...git push origin main..."` is NOT misread
# as a push to main. FAILS CLOSED (forge_deny): a push hidden in sh -c / eval / a pipe-into-shell /
# xargs, an opaque command word ($GIT, $(...)), any refspec/flag-value that is $VAR/${..}/$()/backtick/
# glob/~ or unbalanced, AND every no-refspec (bare) push — the harness finish pushes EXPLICITLY
# (git push -u origin task/<slug>), so a bare push is never legitimate here (locked decision D4).
# The branch-state guard (KEPT, the #7 live test) reads the LIVE current branch and DENIES on
# main/master OR on ANY git error / detached HEAD / empty result — a failed symbolic-ref is an
# unresolvable state, denied, never a fall-through to allow. Reuses forge_unquote / forge_basename.

# Classify a refspec's DESTINATION ref: MAIN (main/master) | AMBIG (unresolvable) | OK:<dst>.
# src:dst -> dst ; :dst (delete) -> dst ; +src (force marker stripped) ; bare ref -> the ref ;
# strips an optional refs/heads/ ; exact-match main/master (so maintenance/mainline are OK).
forge_push_dst_class() {
  local spec dst
  spec="$(forge_unquote "$1")"
  case "$spec" in '' | *'$'* | *'`'* | *'*'* | *'?'* | *'['* | '~'*) printf 'AMBIG'; return ;; esac
  spec="${spec#+}"
  case "$spec" in *:*) dst="${spec##*:}" ;; *) dst="$spec" ;; esac
  case "$dst" in '' | *'$'* | *'`'* | *'*'* | *'?'* | *'['* | '~'*) printf 'AMBIG'; return ;; esac
  dst="${dst#refs/heads/}"
  case "$dst" in main | master) printf 'MAIN'; return ;; esac
  printf 'OK:%s' "$dst"
}

# DENY if a refspec/flag-value resolves to main/master or is unresolvable. Shared by the operand loop
# AND the value-taker scan, so no main/master token can ever go unjudged (the #1 fail-open guard).
forge_push_check_one() {
  case "$(forge_push_dst_class "$1")" in
    MAIN) forge_deny "pushing to main/master is not allowed (open a PR; a human merges) — refspec: $(forge_unquote "$1")" ;;
    AMBIG) forge_deny "push refspec cannot be resolved (variable/substitution/glob/~ — could target main); make it explicit; denied — refspec: $(forge_unquote "$1")" ;;
  esac
}

# Analyze ONE &&/||/;/|-split segment for a dangerous push.
forge_check_push_seg() {
  local seg="$1" t x val _o
  local -a toks=()
  _o="$IFS"
  set -f
  IFS=$' \t\n' read -r -a toks <<<"$seg"
  set +f
  IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0

  # Skip leading VAR=val and known runner/wrapper words to reach the command word (mirrors the write walker).
  local i=0
  while [ "$i" -lt "$n" ]; do
    # A leading shell grouping-open or reserved word is NOT the command word.
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)) ;;
      *=*) i=$((i + 1)) ;;
      # exec/busybox parity: the WRITE/DELETE walkers skip exec + the busybox multicall
      # wrapper; the push/commit walkers did not, so 'exec git push origin main' / 'busybox git push origin main'
      # laundered the git verb past resolution (a live push-to-main / force-push / commit-to-main bypass of the
      # same cardinal class). exec is option-bearing (-a VALUE / -c / -l); an unknown -flag fail-closes.
      sudo | nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv) forge_skip_runner "${toks[$i]}" ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      env) forge_skip_env ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local cw="${toks[$i]}"

  # Opaque command identity ($GIT, $(echo git), backticks): can't confirm it's a push -> if 'push'
  # appears anywhere in the segment, fail closed; else this isn't our concern.
  case "$cw" in
    *'$'* | *'`'*)
      case "$seg" in *push*) forge_deny "opaque command word near a push cannot be verified ($cw) — split/simplify; denied" ;; esac
      return 0
      ;;
  esac

  # Must be git (or the dashed git-push); skip git GLOBAL options to reach the 'push' subcommand.
  # Any other command word -> this segment is not a push (per-segment scoping: gh / git log / echo
  # "...git push..." are ignored here).
  local is_push=0 base
  base="$(forge_basename "$cw")"
  if [ "$base" = "git-push" ]; then
    is_push=1
    i=$((i + 1))
  elif [ "$base" = "git" ]; then
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      case "${toks[$i]}" in
        -c | -C | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) i=$((i + 2)) ;;
        push) is_push=1; i=$((i + 1)); break ;;
        -*) i=$((i + 1)) ;;
        *) return 0 ;;
      esac
    done
  else
    return 0
  fi
  [ "$is_push" = 1 ] || return 0

  # Substitution anywhere in a confirmed push -> refspec/flags unknowable -> deny (mirrors the write walker).
  case "$seg" in *'$('* | *'`'* | *'${'*) forge_deny "git push with a substituted argument cannot be verified — denied" ;; esac

  # Pass 1 — force / mirror / all (deny-aggressive: clustered short flags carrying 'f', leading-+ refspec).
  local force=0 mirrorall=0 e=0
  for x in "${toks[@]:$i}"; do
    [ "$e" = 1 ] && break
    case "$x" in
      --) e=1 ;;
      --force | --force-if-includes | --force-with-lease | --force-with-lease=*) force=1 ;;
      --mirror | --all) mirrorall=1 ;;
      --*) : ;;
      -o | -o*) : ;;
      -*) case "$x" in *f*) force=1 ;; esac ;;
    esac
  done

  # Pass 2 — collect refspec operands; skip flags & value-taker VALUES, routing each skipped value
  # through forge_push_check_one so a 'main' hidden as a flag value can never be silently skipped.
  local -a operands=()
  local j="$i" endo=0
  while [ "$j" -lt "$n" ]; do
    t="${toks[$j]}"
    if [ "$endo" = 0 ]; then
      case "$t" in
        --) endo=1; j=$((j + 1)); continue ;;
        --repo | -o | --push-option | --receive-pack | --exec)
          val="${toks[$((j + 1))]:-}"; [ -n "$val" ] && forge_push_check_one "$val"; j=$((j + 2)); continue ;;
        -o?*) forge_push_check_one "${t#-o}"; j=$((j + 1)); continue ;;
        --repo=* | --push-option=* | --receive-pack=* | --exec=*) forge_push_check_one "${t#*=}"; j=$((j + 1)); continue ;;
        -*) j=$((j + 1)); continue ;;
      esac
    fi
    operands+=("$t")
    case "$(forge_unquote "$t")" in +*) force=1 ;; esac
    j=$((j + 1))
  done

  # Force / mirror / all -> deny (universal; independent of the refspec).
  [ "$force" = 1 ] && forge_deny "force-push is not allowed"
  [ "$mirrorall" = 1 ] && forge_deny "git push --mirror/--all is not allowed (could update main)"

  # Branch-state guard (KEPT — the live :78-79 test). Read the LIVE current branch. A non-zero
  # symbolic-ref (DETACHED HEAD or ANY git error) OR an empty result is an UNRESOLVABLE state ->
  # forge_deny. Deny on the command ERRORING, not just on empty output; never an uncaught abort,
  # never a fall-through to allow.
  local dir cur
  dir="${CLAUDE_PROJECT_DIR:-.}"
  if ! cur="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)"; then
    forge_deny "cannot resolve current branch (detached HEAD or git error) — push denied (unresolvable state)"
  fi
  [ -n "$cur" ] || forge_deny "current branch resolved empty — push denied (unresolvable state)"
  case "$cur" in main | master) forge_deny "pushing while on protected branch '$cur' is not allowed (open a PR; a human merges)" ;; esac

  # Refspecs: operand[0] is the remote; operand[1..] are refspecs. No refspec (bare push or remote-
  # only) -> destination is push.default/upstream, which we do NOT resolve -> hard-deny (D4; finish
  # pushes explicitly, so bare is never legitimate here).
  local nops="${#operands[@]}" k
  if [ "$nops" -le 1 ]; then
    forge_deny "bare 'git push' with no explicit refspec is not allowed — push the branch explicitly (git push -u origin <branch>); denied (unresolvable destination)"
  fi
  for ((k = 1; k < nops; k++)); do
    forge_push_check_one "${operands[$k]}"
  done
  return 0
}

# Deny pushes to main/master (refspec, branch-state, force, mirror); fail-closed on anything unparseable.
forge_check_push() {
  local cmd="$1" seg
  # push-adjacent whole-command fail-closed: eval / pipe-into-shell|xargs / interpreter -c body can
  # hide a push we cannot argv-inspect. Gated on 'push' appearing (even quoted) so ordinary lines pass.
  if printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_])push([^A-Za-z0-9_]|$)'; then
    printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' && forge_deny "git push via eval cannot be verified — run it directly; denied"
    printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(sh|bash|dash|zsh|ksh|busybox|xargs)([[:space:]]|$)' && forge_deny "git push piped into a shell/xargs cannot be verified — denied"
    # Include python/node/perl/ruby (their -c/-e body can hide a push). Blocklist-hardening — `php -r`,
    # `lua -e` and other un-enumerated interpreters still escape; the OS container is the backstop.
    forge_interp_evalbody "$cmd" && forge_deny "git push inside an interpreter -c/-e body cannot be verified — denied"
  fi
  while IFS= read -r seg; do
    forge_check_push_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g')"
}

# ── Commit-to-main refusal, DENY-HOOK TIER ───────────────────────────────────────────────────────────
# main/master advances ONLY by PR-merge; a DIRECT `git commit`/`--amend` on main is the failure this
# closes (and the install-free guard for the agent's tool-path commit — how H2 commits). Per-segment +
# argv-aware (NOT a substring match — the core.hooksPath substring FP is the anti-pattern we avoid). The
# branch is read LIVE and fail-closed on detached/unborn/git-error, mirroring forge_check_push_seg:557
# (symbolic-ref --short — the unborn-branch probe proved abbrev-ref returns "HEAD" for the first commit,
# so it is the ONLY reliable reader). Opaque-vectored commits (eval/-c/pipe) are NOT chased here: the git
# pre-commit hook fires at git-exec time regardless of vector, and --no-verify (the only git-hook bypass)
# is already denied — so this tier stays the FP-free early refusal for the direct path. 'commit' is far
# more common than 'push', so the whole-command opaque scan forge_check_push runs is intentionally omitted.
forge_check_commit_seg() {
  local seg="$1" _o
  local -a toks=()
  _o="$IFS"
  set -f
  IFS=$' \t\n' read -r -a toks <<<"$seg"
  set +f
  IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0
  # Reach the command word past VAR=val + runner/wrapper words (mirrors forge_check_push_seg).
  local i=0
  while [ "$i" -lt "$n" ]; do
    # A leading shell grouping-open or reserved word is NOT the command word.
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)) ;;
      *=*) i=$((i + 1)) ;;
      # exec/busybox parity: the WRITE/DELETE walkers skip exec + the busybox multicall
      # wrapper; the push/commit walkers did not, so 'exec git push origin main' / 'busybox git push origin main'
      # laundered the git verb past resolution (a live push-to-main / force-push / commit-to-main bypass of the
      # same cardinal class). exec is option-bearing (-a VALUE / -c / -l); an unknown -flag fail-closes.
      sudo | nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv) forge_skip_runner "${toks[$i]}" ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      env) forge_skip_env ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local cw="${toks[$i]}" base
  base="$(forge_basename "$cw")"
  # Must be git (or the dashed git-commit); skip git GLOBAL options to reach the 'commit' subcommand.
  local is_commit=0
  if [ "$base" = "git-commit" ]; then
    is_commit=1
  elif [ "$base" = "git" ]; then
    i=$((i + 1))
    while [ "$i" -lt "$n" ]; do
      case "${toks[$i]}" in
        -c | -C | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) i=$((i + 2)) ;;
        commit) is_commit=1; break ;;
        -*) i=$((i + 1)) ;;
        *) return 0 ;;
      esac
    done
  else
    return 0
  fi
  [ "$is_commit" = 1 ] || return 0
  # Confirmed `git commit`: branch-state guard — read the LIVE branch, fail-closed on any unresolvable
  # state (detached HEAD / unborn / git error), deny on main/master. Mirrors forge_check_push_seg:557-567.
  local dir cur
  dir="${CLAUDE_PROJECT_DIR:-.}"
  if ! cur="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)"; then
    forge_deny "cannot resolve current branch (detached HEAD or git error) — commit denied (commit-to-main guard, fail-closed)"
  fi
  [ -n "$cur" ] || forge_deny "current branch resolved empty — commit denied (commit-to-main guard, fail-closed)"
  case "$cur" in
    main | master)
      if [ "${FORGE_ALLOW_MAIN_MERGE:-0}" = "1" ]; then
        forge_log_main_escape "deny-tier: git commit permitted on '$cur' via FORGE_ALLOW_MAIN_MERGE=1"
        return 0
      fi
      forge_deny "committing while on protected branch '$cur' is not allowed — main/master advances ONLY by PR-merge; commit on a task branch (FORGE_ALLOW_MAIN_MERGE=1 opens a supervised, logged merge-finalize door)"
      ;;
  esac
  return 0
}

# Deny a direct `git commit` while on main/master; per-segment, fail-closed (commit-to-main deny tier).
forge_check_commit() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    forge_check_commit_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g')"
}

# ── Launch-time half: env-assignment-prefix classifier (FLOOR-MOVING, BEST-EFFORT DiD) ──────────────────
# Commit 1's in-script pin/strip closes the WITHIN-SCRIPT half. This is a BEST-EFFORT DEFENSE-IN-DEPTH layer
# at the PreToolUse boundary for the LAUNCH-TIME half: an env-assignment prefix the
# loader/interpreter processes BEFORE the harness script's line 1 — `PATH=evil ./run-task.sh` (shims the
# bash interpreter resolved by the shebang), `LD_PRELOAD=evil.so ./run-task.sh` / `BASH_ENV=evil.sh
# ./run-task.sh` (fires attacker code when the loader/shell starts). It is NOT airtight and does NOT claim to
# be — bash grammar admits more launch shapes than any textual classifier can model. The ACTUAL launch-time
# boundary is the OS container + the human merge; this hook raises the cost of the easy,
# unobfuscated shapes. Do not read a completeness guarantee into it.
#
# DESIGN — ALLOWLIST INVERSION. A leading env-assignment that PRECEDES A LAUNCH is DENIED
# unless its NAME is on a small BENIGN allowlist (the env the harness itself uses: FORGE_*/BD_*/TARGET/
# CLAUDE_*/NODE_*/PNPM_*/…). Coverage of the dangerous-name class comes from the allowlist being SMALL, not
# from a deny-list being exhaustive: LD_*/GCONV_PATH/BASH_ENV/ENV and any FUTURE loader/interpreter var all
# fall through to deny WITHOUT being enumerated. "Precedes a launch" is load-bearing: a STANDALONE assignment
# (`count=5`, `out=$(cmd)`) sets a shell var and launders nowhere, so it ALLOWS — the deny is deferred until a
# command word is confirmed after the prefix. An EXPORTED assignment (`export VAR=val`) launders into the
# shell's subsequent launches, so it denies inline. PATH is the one conditionally-benign name — allowed
# generally, denied only alongside a harness entrypoint (_FORGE_ENTRY_RE).
#
# CONCEDED to the OS container (deliberately NOT chased textually — chasing them is the whack-a-mole the
# review diagnosed; the container backstops every one and this classifier does not assert them closed):
# eval/-c/pipe-into-shell wrapping; here-strings (<<<); process substitution <(…)/>(…); command substitution
# `$( … )`/backticks that LAUNCH (`echo $(LD_PRELOAD=x ./run-task.sh)`); compound-command bodies (function
# defs `f(){…}`, case-arm bodies, coproc brace bodies); a separator INSIDE a quoted value
# (`LD_PRELOAD='/a.so:&' cmd` — the sed splitter is quote-blind) or ANSI-C `$'…'` quoting that flips the
# quote-consumer's parity (`A=$'\'' LD_PRELOAD=… cmd` — F2) — both the SAME quote-blindness the floor's
# other sed walkers share; flock -c; awk system(); backslash-newline line continuation; and
# renamed/symlinked/glob/quote-EVADED entrypoint names for the PATH case (`harness/[r]un-task.sh`) — the
# textual entrypoint signal cannot model shell expansion. (A CONCRETE-value opaque prefix like
# `LD_PRELOAD=$(echo x) ./run-task.sh` is NOT conceded — the quote-aware consumer DENIES it.)
# NOTE the strings LD_*/PATH=/BASH_ENV below are MATCH/CLASSIFY TARGETS, not executed.
_FORGE_ENTRY_RE='(^|[^A-Za-z0-9_])(run-task|accept-gate|kill-switch|intake)\.sh([^A-Za-z0-9_]|$)'

# an opaque/unverifiable token: command-substitution, backtick, or a variable expansion.
forge_envprefix_opaque() { case "$1" in *'$('* | *'`'* | *'${'* | *'$'*) return 0 ;; *) return 1 ;; esac; }

# Benign-allowlist test: the env-var NAMES the harness machinery legitimately sets as a leading prefix.
# Derived from the over-block set + a grep of what harness/** and tests/** genuinely set. TIGHT BY DESIGN —
# grow it deliberately when a genuinely-benign harness var is added, NEVER to silence an attack shape.
# CARVE-OUTS first: a few names that MATCH a benign family glob but are binary/code shims with no legit
# leading-prefix use — BD_BIN (shims the bd binary into a privileged launch). RESIDUAL (honest, flagged for a
# separate bead): NODE_OPTIONS(--require)/NODE_PATH are LEFT allowlisted (NODE_* toolchain, dual-use with the
# legit NODE_OPTIONS=--max-old-space-size memory-sizing) — they inject into the harness's node CHILDREN, the
# node-world analog of LD_PRELOAD; this bash-launch-time classifier does not address that node-child vector
# (Commit 1's env -i survival also carries NODE_*); the OS container backstops it.
forge_envprefix_benign() {
  case "$1" in
    BD_BIN) return 1 ;;
    FORGE_* | BD_* | TARGET | CLAUDE_* | NODE_* | NODE | npm_* | PNPM_* | COREPACK_* \
      | CI | LANG | LANGUAGE | LC_* | TZ | TERM | COLUMNS | LINES) return 0 ;;
    *) return 1 ;;
  esac
}

# prefix-position assignment (VAR=val BEFORE the command word). PATH -> mark (entrypoint test decides); benign
# -> skip; else -> RECORD the name in _ep_bad (dynamic scope) — the deny is DEFERRED to the caller, fired only
# if a command word (a launch) is confirmed after the prefix. Value content is irrelevant; the NAME is clean
# even when the value is opaque.
forge_envprefix_assign() {
  local _nm="${1%%=*}"
  case "$_nm" in
    PATH) _ep_path_set=1 ;;
    *) forge_envprefix_benign "$_nm" || { [ -z "$_ep_bad" ] && _ep_bad="$_nm"; } ;;
  esac
}

# exported/declared assignment (export/declare/typeset/readonly/local VAR=val) — launders into the shell's
# subsequent launches, so a non-benign NAME denies INLINE regardless of a following command word. Called only
# on VALUE-bearing operands (a bare `export LD_PRELOAD` by-name is a conceded deliberate multi-step shape).
forge_envprefix_export() {
  local _nm="${1%%=*}"
  case "$_nm" in
    PATH) _ep_path_set=1 ;;
    *) forge_envprefix_benign "$_nm" || forge_deny "exported env-assignment '${_nm}=' launders into the shell's subsequent launches and is not on the harness's benign allowlist — best-effort defense-in-depth deny (fx-ceo/fx-zx0); the OS container is the actual launch-time boundary" ;;
  esac
}

# Advance i past an assignment token whose VALUE may span subsequent whitespace-separated tokens through an
# unclosed '...' / "..." / $( ) / `...` (`x=$(cmd a b)` tokenizes to `x=$(cmd`,`a`,`b)`), so the command-word
# scan is not fooled into seeing a launch INSIDE the value. A char-state-machine — crucially QUOTE-AWARE: a
# literal $( or ( INSIDE single quotes does NOT open a substitution, closing the desync a naive matcher
# found (`LD_PRELOAD='/sandbox/evil.so:$(' ./run-task.sh` and `FORGE_X='(' LD_PRELOAD=evil ./run-task.sh` —
# a stray literal paren that a char-count would mistake for an open subst and use to swallow the launch). The
# value ending at a token boundary -> i stops AT the next token (the command word); running off the segment
# (a |-split capture or an unclosed/invalid value bash would not run) -> i = n, i.e. no command word here.
forge_envprefix_consume_value() {
  local sq=0 dq=0 bt=0 pd=0 esc=0 ch rest
  while [ "$i" -lt "$n" ]; do
    rest="${toks[$i]}"
    while [ -n "$rest" ]; do
      ch="${rest:0:1}"; rest="${rest:1}"
      if [ "$esc" = 1 ]; then esc=0; continue; fi
      if [ "$sq" = 1 ]; then [ "$ch" = "'" ] && sq=0; continue; fi
      case "$ch" in
        '\') esc=1 ;;
        "'") [ "$dq" = 0 ] && sq=1 ;;
        '"') dq=$((1 - dq)) ;;
        '`') bt=$((1 - bt)) ;;
        '$') case "$rest" in '('*) pd=$((pd + 1)); rest="${rest:1}" ;; esac ;;
        ')') [ "$pd" -gt 0 ] && pd=$((pd - 1)) ;;
      esac
    done
    i=$((i + 1))
    [ "$sq" = 0 ] && [ "$dq" = 0 ] && [ "$bt" = 0 ] && [ "$pd" = 0 ] && [ "$esc" = 0 ] && return 0
  done
  return 0
}

# env-as-runner: env ALWAYS puts its VAR=val operands into the launched command's environment, so a
# non-benign operand denies INLINE (the env-prefix-to-launch is definitional). env - / -i / --unset clear the
# env; --split-string/-S restructure and cannot be verified. Path-qualified env (`/usr/bin/env`) reaches here
# via the `*/env` arm in the seg walker.
forge_envprefix_skip_env() {
  local rest first
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in
      -- | -) i=$((i + 1)) ;;
      --split-string | --split-string=*) forge_deny "env --split-string restructures the command past this best-effort env-prefix check — denied (fx-ceo/fx-zx0); the OS container is the launch-time boundary" ;;
      --unset | --chdir) i=$((i + 2)) ;;
      --*) i=$((i + 1)) ;;
      -?*)
        rest="${toks[$i]:1}"; i=$((i + 1))
        while [ -n "$rest" ]; do
          first="${rest:0:1}"; rest="${rest:1}"
          case "$first" in
            S) forge_deny "env -S restructures the command past this best-effort env-prefix check — denied (fx-ceo/fx-zx0); the OS container is the launch-time boundary" ;;
            u | C) [ -z "$rest" ] && i=$((i + 1)); break ;;
          esac
        done ;;
      *=*) forge_envprefix_export "${toks[$i]}"; i=$((i + 1)) ;;
      *) break ;;
    esac
  done
}

# per-segment: collect leading prefix assignments (skipping redirects/keywords/runners), then DENY a recorded
# non-benign one ONLY IF a command word (a launch) follows. The compound-keyword skip-list includes if/case/
# coproc. Leading/interspersed REDIRECTS are skipped (bash allows redirect & assignment in any
# prefix order) — the gap a naive matcher would leave (`</dev/null LD_PRELOAD=x cmd`).
forge_check_envprefix_seg() {
  local seg="$1" _o
  local -a toks=()
  _o="$IFS"; set -f; IFS=$' \t\n' read -r -a toks <<<"$seg"; set +f; IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0
  local i=0 _ep_bad="" _ep_launch=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | if | then | do | else | elif | while | until | case | coproc) i=$((i + 1)) ;;
      # a redirection in the prefix — skip the operator (and a DETACHED target token). MUST precede *=* so a
      # token like `>f=g` (redirect to a file named f=g) is treated as a redirect, not an assignment. Covers
      # multi-digit fds (`10>out`), &>/&>>/>&/<& dup forms, and the {name}> named-fd form (its leading `{` is
      # already stripped to `name}>` by the group-strip above) — adversarial-review finds. A bare operator
      # (target is the NEXT token) skips 2; a glued/dup/named-fd token skips 1 (skip-1 is the fail-safe default).
      [0-9]*'<'* | [0-9]*'>'* | '<'* | '>'* | '&>'* | '&>>'* | [A-Za-z_]*'}<'* | [A-Za-z_]*'}>'* | [A-Za-z_]*'}>>'*)
        case "${toks[$i]}" in
          '<' | '>' | '>>' | '>|' | '<>' | '<&' | '>&' | '&>' | '&>>' \
            | [0-9]*'<' | [0-9]*'>' | [0-9]*'>>' | [0-9]*'>|' | [0-9]*'<>' | [0-9]*'<&' | [0-9]*'>&') i=$((i + 2)) ;;
          *) i=$((i + 1)) ;;
        esac ;;
      *=*) forge_envprefix_assign "${toks[$i]}"; forge_envprefix_consume_value ;;
      export | readonly | declare | typeset | local)
        # only VALUE-bearing operands (`VAR=val`) are env-laundering; a BARE name (`declare -A map`,
        # `readonly X`, `export LD_PRELOAD`) is not (export-by-name is a deliberate multi-step shape — conceded).
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in *=*) forge_envprefix_export "${toks[$i]}" ;; esac
          i=$((i + 1))
        done
        return 0 ;;
      # a runner/wrapper word IS a launch — bash execs it WITH the leading env-assignment live, even when it
      # is the LAST token (no wrapped command follows) or when its own arg-parse hides the command word
      # (`LD_PRELOAD=x nice`, `LD_PRELOAD=x taskset -c0 cmd`). So mark _ep_launch=1 here; the deferred deny then
      # fires for a recorded non-benign assignment regardless of whether a command word remains (F3/F4).
      sudo | nohup | busybox) _ep_launch=1; i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv) _ep_launch=1; forge_skip_runner "${toks[$i]}" ;;
      exec)
        _ep_launch=1
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in --) i=$((i + 1)); break ;; -a) i=$((i + 2)) ;; -c | -l | -cl | -lc) i=$((i + 1)) ;; -*) i=$((i + 1)) ;; *) break ;; esac
        done ;;
      env | */env) forge_envprefix_skip_env ;;
      *) break ;;
    esac
  done
  # a LAUNCH happens if a command word remains (i < n) OR a runner/wrapper was reached (_ep_launch, F3/F4)
  # => fire the deferred deny for a recorded non-benign assignment, plus the PATH/opaque arms.
  [ "$i" -lt "$n" ] && _ep_launch=1
  [ "$_ep_launch" = 1 ] && [ -n "$_ep_bad" ] && forge_deny "leading env-assignment '${_ep_bad}=' before a launch is not on the harness's small benign allowlist — best-effort defense-in-depth deny (launch-time); the OS container is the actual launch-time boundary, not this hook"
  [ "$i" -lt "$n" ] && forge_envprefix_opaque "${toks[$i]}" && [ "$_ep_path_set" = 1 ] && _ep_opaque_cw=1
  return 0
}

forge_check_envprefix() {
  local cmd="$1" seg
  local _ep_path_set=0 _ep_opaque_cw=0
  # Split on && || |& ; | and a bare & (background/sequencing). FIRST protect EVERY redirect operator that
  # itself contains a `|` or `&` — the clobber-override `>|` / `N>|` (placeholder \x05; F1) AND the
  # &-family `&>> &> >& <&` (\x01-\x04) — so an UNQUOTED redirect operator is never split mid-token; THEN split;
  # THEN restore. (`>|` must be protected BEFORE the `|` split, not after, or its `|` severs the leading
  # assignment from the launch — the F1 HIGH bypass: `MARKER=x >| f printenv MARKER`.) Mirrors the proven
  # forge_check_mutators splitter (lib.sh ~1011). CONCEDED residual (quote-blind, the SAME limitation as the
  # floor's other sed splitters): a separator INSIDE a quoted value (`LD_PRELOAD='/a.so:&' cmd`) still
  # over-splits and can drop a crafted loader segment — the OS container backstops it; realistic UNQUOTED shapes are covered EXCEPT an unquoted
  # separator inside an expansion (`${x:-a;b}`, `$(...)`), which fractures this pre-splitter before
  # forge_envprefix_consume_value can rejoin it (ALLOW while bash still carries the loader — marker-
  # proven). That is the conceded quote/grammar-blind class, OS-container-backstopped
  # — this splitter does NOT cover all unquoted shapes.
  while IFS= read -r seg; do
    forge_check_envprefix_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/>\|/\x05/g; s/&>>/\x01/g; s/&>/\x02/g; s/>&/\x03/g; s/<&/\x04/g; s/(\&\&|\|\||\|&|;|\|)/\n/g; s/&/\n/g; s/\x05/>|/g; s/\x04/<\&/g; s/\x03/>\&/g; s/\x02/\&>/g; s/\x01/\&>>/g')"
  if [ "$_ep_path_set" = 1 ]; then
    [ "$_ep_opaque_cw" = 1 ] && forge_deny "an opaque command word with a PATH= prefix cannot be verified not to shim a harness entrypoint — best-effort defense-in-depth deny (fx-ceo); the OS container is the launch-time boundary"
    printf '%s' "$cmd" | grep -Eq "$_FORGE_ENTRY_RE" && forge_deny "PATH= set alongside a harness entrypoint could shim its launch interpreter — best-effort defense-in-depth deny (launch-time); the OS container is the actual launch-time boundary"
  fi
  return 0
}

# ── Git-as-floor-mutator guard ──────────────────────────────────────────────────────────────────────────
# `git checkout <ref> -- <path>` and `git restore [--source=<ref>] <path>` overwrite the working tree at
# <path> from a ref/index — a floor WRITE the mutator walker never modelled (only commit/push touch the git
# verb). So `git checkout old-ref -- .claude/hooks/lib.sh` reverted the deny floor to a historical (possibly
# vulnerable) version, and `git restore .beads/issues.jsonl` rewrote the bd-managed ledger — both ALLOW.
# This guard routes the PATHSPEC operands of the floor-mutating verbs (checkout / restore; dashed forms too)
# through forge_enforce_class. A tree-ish / branch / ref (HEAD~5, main, feature/x, @{-1}) classifies 'ok' —
# refs are never floor paths — so only a real floor pathspec denies and a benign branch switch (no pathspec)
# is untouched. Argv-decidable + over-block-safe. Per-segment, mirroring forge_check_push_seg /
# forge_check_commit_seg (incl. the group-skip + the exec/busybox/runner resolution).
forge_git_path_check() {
  local verb="$1" raw="$2" p
  p="$(forge_norm_path "$(forge_unquote "$raw")")"
  # A '..' pathspec can traverse into the floor (symlink-unsafe to resolve textually) -> fail closed.
  case "/$p/" in */../*) forge_deny "git $verb with a '..' pathspec cannot be verified — denied" ;; esac
  case "$(forge_enforce_class "$p")" in
    git) forge_deny "git $verb targeting .git/ is not allowed (path: $(forge_unquote "$raw"))" ;;
    beads) forge_deny "git $verb targeting the bd-managed .beads/ ledger is not allowed — mutate via bd (path: $(forge_unquote "$raw"))" ;;
    enforce) forge_deny "git $verb overwriting an enforcement/harness path from a ref/index is not allowed (path: $(forge_unquote "$raw"))" ;;
  esac
}

# Bound a git patch / mailbox by its git-DECODED target
# paths. `git apply --numstat -z` is READ-ONLY (reports add/del/path, writes nothing) and lets GIT resolve
# C-quoted/octal-escaped headers ("a/\056claude/hooks/lib.sh" -> .claude/hooks/lib.sh), -p path-stripping,
# renames, and an mbox's diff body (email headers ignored) — exactly the decode the prior literal patch-grep
# MISSED (the apply-octal floor-disable). Classify the decoded paths; an unparseable
# patch/mailbox -> fail-closed DENY. Shared by the apply and am verbs so they cannot drift. $1 = a label.
forge_git_patch_floor() {
  local what="$1"; shift
  local dir np nr tok
  local -a files=() dflags=()
  dir="${CLAUDE_PROJECT_DIR:-.}"
  # IMPOSE at -p0 — robust by construction, not a blacklist or an agent-driven -p (both are chases git's grammar
  # defeats: a flag blacklist misses unique-prefix abbreviations --quie==--quiet; an am-style -p parse misses
  # CLUSTERED -p, e.g. -qp0==-q -p0). Callers pass patch-file operand(s) (+ maybe a -p<n>); we DROP the -p and
  # FORCE -p0 so the decode is immune to the agent's -p in EVERY form. At -p0 `git apply --numstat -z` reports
  # the FULL header path, and a real floor write at ANY agent -p carries the floor token in its full path (-p
  # strips only LEADING components) -> no -p value, cluster, abbreviation, or silencing flag can hide a floor
  # write. Forward reports content/create/delete + a rename DEST; reverse `-R` reports a rename SOURCE; git
  # decodes octal / C-quoting / =-in-path / same-prefix brace in BOTH. Union-grep for floor; EITHER parse error
  # -> fail-closed. Any token other than -p<n>/operand -> fail-closed (callers reconstruct; a stray flag is a
  # caller bug). Standard a/b patches at the default -p1 get the SAME verdict at -p0 (the a/ prefix carries no
  # floor token); only an exotic high-`-p` re-root patch that strips the token away over-blocks (fail-safe).
  for tok in "$@"; do
    case "$tok" in
      -p[0-9]*) ;;
      --directory=*) dflags+=("$tok") ;;
      -*) forge_deny "$what: bounding accepts only -p<n>, --directory=<dir>, and a patch file (callers reconstruct a clean invocation); unexpected option ($tok) — denied (fail-closed)" ;;
      *) files+=("$tok") ;;
    esac
  done
  [ "${#files[@]}" -gt 0 ] || forge_deny "$what: no patch operand to bound — denied (fail-closed)"
  np="$(set -o pipefail; git -C "$dir" apply --numstat -z -p0 "${dflags[@]}" "${files[@]}" 2>/dev/null | tr '\0' '\n')" ||
    forge_deny "$what: cannot parse the patch/mailbox to bound its targets to non-floor paths — denied (fail-closed)"
  nr="$(set -o pipefail; git -C "$dir" apply -R --numstat -z -p0 "${dflags[@]}" "${files[@]}" 2>/dev/null | tr '\0' '\n')" ||
    forge_deny "$what: cannot reverse-parse the patch/mailbox to bound its rename source — denied (fail-closed)"
  printf '%s\n%s\n' "$np" "$nr" |
    grep -Eq '(^|[^A-Za-z0-9_.-])((\.git|\.beads|\.claude/hooks|harness|\.harness)(/|$|[^A-Za-z0-9_-])|\.claude/settings)' &&
    forge_deny "$what would write/rename an enforcement/.git/.beads/harness path (git-decoded patch target) — denied"
}

forge_check_git_seg() {
  local seg="$1" t _o
  local -a toks=()
  _o="$IFS"
  set -f
  IFS=$' \t\n' read -r -a toks <<<"$seg"
  set +f
  IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0

  # Reach the command word past leading grouping/keyword tokens, VAR=val, and runner/wrapper words
  # (incl. exec + the busybox multicall wrapper — mirrors the WRITE/DELETE walkers so a laundered git verb
  # cannot slip past). Mirrors forge_check_push_seg / forge_check_commit_seg.
  local i=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)) ;;
      *=*) i=$((i + 1)) ;;
      sudo | nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv) forge_skip_runner "${toks[$i]}" ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      env) forge_skip_env ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local cw="${toks[$i]}" base verb=""
  base="$(forge_basename "$cw")"

  # The floor-mutating git WRITE-verbs. checkout/restore/switch/mv/
  # reset write argv-NAMED paths (target is argv-classifiable -> route the pathspec through forge_enforce_class,
  # exactly like a cp/mv dest). apply/stash write PROGRAM-INTERNAL targets (inside the patch / the stash, NOT
  # argv-visible) -> fail-closed unless the target can be statically bounded to non-floor. Dashed git-<verb>
  # forms are equivalent. Any OTHER git subcommand (log/diff/show/add/commit/push/pull/merge/...) does not
  # write an argv-named floor path here (commit/push have their own guards; whole-tree pull/merge/rebase and
  # `git reset --hard <ref>` with no floor pathspec are the documented class-2 broad-revert residual,
  # witness-drift-detected + container-deferred) -> allow. RESIDUAL: a genuinely-NEW git
  # write-verb naming a floor path is NOT blanket-caught — a catch-all over-blocks legit git (`git add harness`
  # stages the dir; `git log <floor>` reads it), so the unbounded write-verb tail is the container's job.
  case "$base" in
    git-checkout) verb="checkout"; i=$((i + 1)) ;;
    git-restore) verb="restore"; i=$((i + 1)) ;;
    git-switch) verb="switch"; i=$((i + 1)) ;;
    git-mv) verb="mv"; i=$((i + 1)) ;;
    git-reset) verb="reset"; i=$((i + 1)) ;;
    git-apply) verb="apply"; i=$((i + 1)) ;;
    git-am) verb="am"; i=$((i + 1)) ;;
    git-rm) verb="rm"; i=$((i + 1)) ;;
    git-sparse-checkout) verb="sparse-checkout"; i=$((i + 1)) ;;
    git-stash) verb="stash"; i=$((i + 1)) ;;
    git-checkout-index) verb="checkout-index"; i=$((i + 1)) ;;
    git-update-index) verb="update-index"; i=$((i + 1)) ;;
    git)
      i=$((i + 1))
      while [ "$i" -lt "$n" ]; do
        case "${toks[$i]}" in
          -c | -C | --git-dir | --work-tree | --namespace | --super-prefix | --config-env) i=$((i + 2)) ;;
          checkout | restore | switch | mv | reset | apply | am | rm | sparse-checkout | stash | checkout-index | update-index) verb="${toks[$i]}"; i=$((i + 1)); break ;;
          -*) i=$((i + 1)) ;;
          *) return 0 ;;
        esac
      done
      ;;
    *) return 0 ;;
  esac
  [ -n "$verb" ] || return 0

  # Substitution in a confirmed git write-verb -> target unknowable -> fail closed (mirrors the others).
  case "$seg" in *'$('* | *'`'* | *'${'*) forge_deny "git $verb with a substituted argument cannot be verified — denied" ;; esac

  # apply: write targets live INSIDE the patch (or stdin) -> program-internal. Bound by reading the patch
  # operand: a patch from stdin / no file / unreadable / a grep-DEFEATING option (--directory prepends a path,
  # --unsafe-paths escapes the repo) cannot be bounded -> fail-closed DENY; a patch whose text references ANY
  # floor path -> DENY; an argv-visible patch provably free of floor paths -> ALLOW (no over-block of a legit
  # non-floor patch). The threat (an injected agent's `git apply floor-neuter.patch`) is exactly this.
  if [ "$verb" = "apply" ]; then
    local k tk sawpatch=0 endo=0 pnum=1 droot=""
    local -a patches=() dopt=()
    for ((k = i; k < n; k++)); do
      tk="${toks[$k]}"
      if [ "$endo" = 1 ]; then sawpatch=1; patches+=("$tk"); continue; fi
      case "$tk" in
        --) endo=1 ;;
        -) forge_deny "git apply reads the patch from stdin — its targets cannot be bounded to non-floor paths — denied" ;;
        --unsafe-paths | --uns*) forge_deny "git apply --unsafe-paths escapes the working tree — its write target cannot be statically bounded — denied" ;;
        --d*=*) droot="${tk#*=}" ;;
        --d*) k=$((k + 1)); droot="${toks[$k]:-}" ;;
        -p[0-9]*) pnum="${tk#-p}" ;;
        -p) k=$((k + 1)); pnum="${toks[$k]:-1}" ;;
        -*) : ;;
        *) sawpatch=1; patches+=("$tk") ;;
      esac
    done
    [ "$sawpatch" = 1 ] || forge_deny "git apply with no patch file (stdin) cannot be bounded to non-floor paths — denied"
    # IMPOSE: reconstruct a CLEAN invocation (mirrors the am twin) — pass ONLY -p<n> + the patch operand(s), so
    # NO caller flag (incl. git's unique-prefix abbreviations like --quie==--quiet, which an exact-match strip
    # cannot catch) reaches the bounding numstats to silence / reformat / validate them.
    [ -n "$droot" ] && dopt=(--directory="$droot")
    forge_git_patch_floor "git apply" "-p$pnum" "${dopt[@]}" "${patches[@]}"
    return 0
  fi

  # am: a mailbox of patches — the apply-twin (same PROGRAM-INTERNAL class). Resolution subcommands
  # (--continue/--skip/--abort/--quit) finish an ALREADY-vetted am (no new patch, no new write) -> allow; no
  # mailbox file (stdin) -> fail-closed; otherwise bound the mailbox file(s) by git's decoded targets.
  if [ "$verb" = "am" ]; then
    local k tk resolved=0 sawmbox=0 endo=0 dir amtd amsg pnum=1 droot=""
    local -a mboxes=()
    for ((k = i; k < n; k++)); do
      tk="${toks[$k]}"
      if [ "$endo" = 1 ]; then sawmbox=1; mboxes+=("$tk"); continue; fi
      case "$tk" in
        --) endo=1 ;;
        --continue | --skip | --abort | --quit | --resolved | -r) resolved=1 ;;
        -) forge_deny "git am reads the mailbox from stdin — its targets cannot be bounded to non-floor paths — denied" ;;
        --d*=*) droot="${tk#*=}" ;;
        --d*) k=$((k + 1)); droot="${toks[$k]:-}" ;;
        -p[0-9]*) pnum="${tk#-p}" ;;
        -p) k=$((k + 1)); pnum="${toks[$k]:-1}" ;;
        -*) : ;;
        *) sawmbox=1; mboxes+=("$tk") ;;
      esac
    done
    [ "$resolved" = 1 ] && return 0
    [ "$sawmbox" = 1 ] || forge_deny "git am with no mailbox file (stdin) cannot be bounded to non-floor paths — denied"
    # git am transfer-DECODES via mailsplit|mailinfo (quoted-printable/base64) BEFORE applying — numstat on the
    # RAW mailbox would MISS a path hidden by Content-Transfer-Encoding (the am-side inverse of the apply-octal
    # hole). Decode the way am does: split the mailbox, mailinfo-decode each message, numstat the DECODED patch.
    # Any failure to split/decode/parse -> fail-closed DENY. (A blocked attack may leak the mktemp dir; benign.)
    dir="${CLAUDE_PROJECT_DIR:-.}"
    amtd="$(mktemp -d)" || forge_deny "git am: cannot allocate a workspace to bound the mailbox — denied (fail-closed)"
    git -C "$dir" mailsplit -o"$amtd" -- "${mboxes[@]}" >/dev/null 2>&1 ||
      { rm -rf "$amtd"; forge_deny "git am: cannot split the mailbox to bound its targets — denied (fail-closed)"; }
    for amsg in "$amtd"/[0-9]*; do
      [ -e "$amsg" ] || { rm -rf "$amtd"; forge_deny "git am: empty mailbox — cannot bound its targets — denied (fail-closed)"; }
      git -C "$dir" mailinfo "$amtd/.msg" "$amtd/.patch" <"$amsg" >/dev/null 2>&1 ||
        { rm -rf "$amtd"; forge_deny "git am: cannot mailinfo-decode a message to bound its targets — denied (fail-closed)"; }
      local -a dopt=(); [ -n "$droot" ] && dopt=(--directory="$droot")
      forge_git_patch_floor "git am" "-p$pnum" "${dopt[@]}" "$amtd/.patch"
    done
    rm -rf "$amtd"
    return 0
  fi

  # stash pop|apply: write targets live in the stash -> program-internal. Bound via `git stash show
  # --name-only`: a floor path in the stash -> DENY; the stash cannot be listed -> fail-closed DENY; a stash
  # provably free of floor paths -> ALLOW. Other stash subcommands (push/save/list/show/drop/clear/branch)
  # do not write the working tree here -> ALLOW.
  if [ "$verb" = "stash" ]; then
    local k="$i" sub="" sref="stash@{0}" dir files f
    while [ "$k" -lt "$n" ]; do case "${toks[$k]}" in -*) k=$((k + 1)) ;; *) sub="${toks[$k]}"; k=$((k + 1)); break ;; esac; done
    case "$sub" in
      pop | apply)
        while [ "$k" -lt "$n" ]; do case "${toks[$k]}" in -*) k=$((k + 1)) ;; *) sref="${toks[$k]}"; break ;; esac; done
        dir="${CLAUDE_PROJECT_DIR:-.}"
        files="$(git -C "$dir" stash show --name-only "$sref" 2>/dev/null)" ||
          forge_deny "git stash $sub: cannot list the stash ($sref) to bound its write to non-floor paths — denied"
        [ -n "$files" ] || forge_deny "git stash $sub: empty/unresolvable stash file list — cannot bound — denied"
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          case "$(forge_enforce_class "$(forge_norm_path "$f")")" in
            git | beads | enforce) forge_deny "git stash $sub would write a floor path from the stash ($f) — denied" ;;
          esac
        done <<<"$files"
        ;;
    esac
    return 0
  fi

  # sparse-checkout reshapes the working tree to the cone — its DELETION set is the cone COMPLEMENT (every
  # path OUTSIDE the cone, incl. the deny floor AND this hook itself), which is NOT argv-named and cannot be
  # bounded; the keystone cannot backstop it (it removes the hook the keystone lives in). Fail-closed on the
  # cone-mutating subcommands; `list` is read-only.
  if [ "$verb" = "sparse-checkout" ]; then
    local k="$i" sub=""
    while [ "$k" -lt "$n" ]; do case "${toks[$k]}" in -*) k=$((k + 1)) ;; *) sub="${toks[$k]}"; break ;; esac; done
    case "$sub" in
      set | add | reapply | init | disable | "") forge_deny "git sparse-checkout $sub reshapes the working tree by the cone COMPLEMENT (an unbounded deletion set including the deny floor and this hook) — cannot be argv-bounded; denied (fail-closed)" ;;
    esac
    return 0
  fi

  # The F-INDEX-NEUTER chain. `git update-index --cacheinfo
  # <mode>,<sha>,<floor>` STAGES an arbitrary blob at a floor path; `git checkout-index -f -- <floor>`
  # MATERIALISES it to the worktree — both ALLOWed (unmodeled verbs) and chained they neuter the floor with
  # the witness defeated (forge_witness_* live in the lib.sh the chain replaces) and no container today. Route
  # their argv-named path operands through forge_git_path_check (same shape as checkout/restore). checkout-index
  # --stdin (unbounded pathspecs) / --prefix (re-roots output) cannot be bounded -> fail-closed; the -a whole-
  # tree form has no floor pathspec -> allowed (the staging step is denied here, so the index floor entry
  # cannot be argv-poisoned with arbitrary content). update-index --index-info/--stdin read entries from stdin
  # -> fail-closed; --cacheinfo's path (comma form mode,sha,PATH or the 3-token old form) routes through too.
  if [ "$verb" = "checkout-index" ]; then
    local k tk endo=0
    for ((k = i; k < n; k++)); do
      tk="${toks[$k]}"
      if [ "$endo" = 1 ]; then forge_git_path_check "checkout-index" "$tk"; continue; fi
      case "$tk" in
        --) endo=1 ;;
        --stdin) forge_deny "git checkout-index --stdin reads its pathspec set from stdin — cannot be bounded — denied" ;;
        --prefix | --prefix=*) forge_deny "git checkout-index --prefix re-roots the output path and cannot be statically bounded — denied" ;;
        -*) : ;;
        *) forge_git_path_check "checkout-index" "$tk" ;;
      esac
    done
    return 0
  fi
  if [ "$verb" = "update-index" ]; then
    local k tk nx endo=0
    for ((k = i; k < n; k++)); do
      tk="${toks[$k]}"
      if [ "$endo" = 1 ]; then forge_git_path_check "update-index" "$tk"; continue; fi
      case "$tk" in
        --) endo=1 ;;
        --index-info | --stdin) forge_deny "git update-index $tk reads index entries from stdin — cannot be bounded — denied" ;;
        --cacheinfo)
          nx="${toks[$((k + 1))]:-}"
          case "$nx" in
            *,*,*) forge_git_path_check "update-index" "${nx#*,*,}" ;;
            *) forge_git_path_check "update-index" "${toks[$((k + 3))]:-}" ;;
          esac
          ;;
        --cacheinfo=*) nx="${tk#--cacheinfo=}"; forge_git_path_check "update-index" "${nx#*,*,}" ;;
        -*) : ;;
        *) forge_git_path_check "update-index" "$tk" ;;
      esac
    done
    return 0
  fi

  # checkout / restore / switch / mv / reset / rm: argv-classifiable targets. Route every PATHSPEC operand
  # through forge_git_path_check. Skip option VALUES that are refs/branches (-b/-B/--orphan new-branch,
  # -s/--source restore tree). After `--` everything is a pathspec. A tree-ish/branch/ref classifies 'ok'
  # (so a branch switch / `git reset --hard <ref>` with no floor pathspec is allowed — the class-2 residual);
  # only a literal floor pathspec denies. (mv routes ALL operands: it writes the dest AND removes the src.)
  local j="$i" endo=0
  while [ "$j" -lt "$n" ]; do
    t="${toks[$j]}"
    if [ "$endo" = 0 ]; then
      case "$t" in
        --) endo=1; j=$((j + 1)); continue ;;
        --pathspec-from-file | --pathspec-from-file=*) forge_deny "git $verb --pathspec-from-file reads an unverifiable pathspec set — denied" ;;
        -b | -B | --orphan | -s | --source) j=$((j + 2)); continue ;;
        --source=* | --orphan=*) j=$((j + 1)); continue ;;
        -*) j=$((j + 1)); continue ;;
      esac
    fi
    forge_git_path_check "$verb" "$t"
    j=$((j + 1))
  done
  return 0
}

# Deny `git checkout/restore` that overwrites the floor from a ref/index; per-segment, fail-closed.
# ── Agent bd close-verb deny (FLOOR, floor-MOVING) ───────────────────────────────────────────────────────
# The done-edge (a bead reaching status=closed) is convention-only today: nothing stops the agent typing
# `bd close <id>` / `bd update <id> -s closed` / `bd import <file-with-status:closed>` at the top level. Deny
# the agent's DIRECT close-verbs wholesale. The harness runs NONE of these as a top-level agent tool-call:
# the sole automated close is the reconcile SUBPROCESS (beads-lib.sh forge_bd close), invisible to PreToolUse
# (which gates only on .tool_input.command) — so the deny over-blocks ZERO automation. Finish uses `--status
# in_review`, start `--claim`, kill-switch `--status open`; the harness only `bd export`s. The subprocess-
# exemption is load-bearing: if a future refactor ever surfaced `bd close` into a top-level agent Bash
# call, this deny would break sync — pin the invariant. BEST-EFFORT: these are CONCEDED to
# the OS container and NOT claimed closed — script-file indirection (`bash sandbox/x.sh` containing bd close),
# non-enumerated interpreters (php -r/lua -e), env -i survival, an EMBEDDED-partial-quoted verb/value
# (`bd clo'se' X`, `bd update -s clo'sed'` — bash concatenates them but no static tokenizer can), bd GLOBALS
# or a quoted verb INTERPOSED in an eval / pipe / interpreter -c launder body (`eval bd -C . close X`,
# `bash -c 'bd -C . close X'` — the adjacency phrase below only spots a bare `bd <verb>` in a launder body),
# and GNU `parallel`. The whole-command launder guard is a TEXT SCAN (like forge_check_rm): a benign command
# that merely CONTAINS a literal `bd <close-verb>` in a quoted string AND an interpreter/pipe fails CLOSED
# (`git commit -m "fix bd close bug" && python3 -c ...` — same shared limitation the rm/write gates carry).
# This hardens the DIRECT hand-typed surface (the realistic accidental / convention-violation vector),
# including a WHOLLY-quoted verb/value (`bd "close" X`, `bd -s "closed"`), the documented `bd todo done` alias
# for `bd close`, and `xargs bd close`; it is NOT an airtight guarantee — never claim the done-edge
# is "secured / closed by construction". CONCEDED to the OS container (determined static-tokenizer evasion, not
# an accidental vector; named by an adversarial review pass): a multi-word QUOTED global VALUE spanning
# whitespace tokens (`bd --db "/a b/x" close`, `bd todo --actor "a b" done`) desyncs the positional scan; a
# backslash-newline continuation splits the verb across the segment reader; `${IFS}`/globals interposed in a
# launder body; and a path-qualified runner (`/usr/bin/sudo -u x bd close`) evades the runner word-match. `$'...'`
# ANSI-C quoting IS caught (the substitution fail-closed guard below).

# Append to the bd-close escape audit log when FORGE_ALLOW_BD_CLOSE=1 permits an agent-mediated triage close.
# Mirrors forge_log_main_escape (records actor) — a hand-close is an authority/outcome event, must be
# attributable; NOT forge_log_bypass (no actor).
forge_log_bd_escape() {
  local d; d="$(forge_harness_dir 2>/dev/null)" || return 0
  [ -n "$d" ] || return 0
  mkdir -p "$d" 2>/dev/null
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ 2>/dev/null || printf now)" "${USER:-$(id -un 2>/dev/null || printf unknown)}" "$1" >>"$d/bd-close-escape.log" 2>/dev/null
  return 0
}

# The supervised triage door. FORGE_ALLOW_BD_CLOSE=1 (read via env EXPANSION at hook-exec time — the
# same agent-unsettable property as FORGE_ALLOW_HOOK_EDIT; NEVER via forge_json/CMD, which would hand the
# agent a self-open) opens a supervised, actor-logged door: log then return 0 (allow). CONVENIENCE, not a
# necessity — the reconcile close is subprocess-exempt (automation needs no door) and the canonical human
# triage path is a direct `bd close` in a NON-agent shell the hook never sees. MUST default 0, be left unset
# in unattended/autonomous runs, and be scoped as a single-command launch prefix (never a session-wide export).
forge_bd_deny() {
  if [ "${FORGE_ALLOW_BD_CLOSE:-0}" = "1" ]; then
    forge_log_bd_escape "deny-tier: bd close-verb permitted via FORGE_ALLOW_BD_CLOSE=1 ($1)"
    return 0
  fi
  forge_deny "$1 — the done-edge is bd-managed: a merged PR auto-closes via the reconcile subprocess (invisible to this hook) and human triage closes in a non-agent shell. FORGE_ALLOW_BD_CLOSE=1 opens a supervised, actor-logged door for in-session agent-mediated triage (convenience, not necessity)."
}

# forge_check_bd <cmd> — deny the agent's DIRECT bd close-verbs. Mirrors forge_check_git: a whole-command
# launder guard (mirror forge_check_rm) + a per-segment walker (mirror forge_check_git_seg).
forge_check_bd() {
  local cmd="$1" seg
  # Whole-command launder guard. Gate on the ADJACENT phrase `bd <close-verb>` (bd immediately followed —
  # whitespace only — by a close-verb), NOT a loose bd-word + close-verb-word co-occurrence. This is what
  # keeps benign commands from over-blocking: `bd show && python3 -c "import json"`, `bd export | python3 -c
  # "..."`, a `do…done` loop over `bd ready`, and `bd list | grep import` all LACK the phrase and pass. Then
  # deny only when that phrase is laundered through a pipe-into-shell / eval / interpreter -c body the
  # per-segment walker cannot see into (`bash -c 'bd close X'`, `eval bd close X`, `echo bd close X | bash`).
  # The .beads launder-gate (~lib.sh:988) is floor-PATH-gated and never fires on a pathless `bd close`, so
  # this carries its OWN bd-keyed guard. CONCEDED (best-effort): bd globals / a quoted verb INSIDE the body.
  if printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_.-])bd[[:space:]]+(close|done|import|supersede|duplicate|todo[[:space:]]+done)([^A-Za-z0-9_]|$)'; then
    printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(sh|bash|dash|zsh|ksh|busybox|xargs|python[0-9.]*|node|perl|ruby)([[:space:]]|$)' && forge_bd_deny "a bd close-verb piped into a shell/interpreter cannot be verified"
    printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' && forge_bd_deny "a bd close-verb via eval cannot be verified"
    forge_interp_evalbody "$cmd" && forge_bd_deny "a bd close-verb inside an interpreter -c/-e body cannot be verified"
  fi
  # Per-segment: split on && || ; | and a bare & (mirror forge_check_writes:1009-1011 — NOT the git splitter,
  # which misses a bare `&`, so `foo & bd close X` would survive it), protecting the &-family redirects.
  while IFS= read -r seg; do
    forge_check_bd_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g; s/&>>/\x01/g; s/&>/\x02/g; s/>&/\x03/g; s/&/\n/g; s/\x03/>\&/g; s/\x02/\&>/g; s/\x01/\&>>/g')"
}

forge_check_bd_seg() {
  local seg="$1" _o
  local -a toks=()
  _o="$IFS"
  set -f
  IFS=$' \t\n' read -r -a toks <<<"$seg"
  set +f
  IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0

  # Reach the command word past leading grouping/keyword tokens, VAR=val, runner/wrappers, exec, env — copied
  # VERBATIM from forge_check_git_seg's leading-skip (shared grammar via bash dynamic scope on toks/n/i) — plus
  # an xargs arm (mirror forge_check_rm_seg:338): resolve THROUGH `xargs` (past its options) to the real
  # command word, so `xargs bd close X` / `xargs -I{} bd close {}` walk to bd and dispatch (the non-piped xargs
  # form the |-launder gate above cannot see). `xargs bd list` still resolves to a bd READ -> allowed.
  local i=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)) ;;
      *=*) i=$((i + 1)) ;;
      # sudo routes through forge_skip_runner (NOT the zero-arg arm) ONLY in this bd walker so
      # `sudo -u X bd close` / `sudo -n bd close` resolve THROUGH sudo's options to `bd` and dispatch (defense-
      # in-depth over the platform safety hook that already blocks sudo). nohup/busybox stay zero-arg.
      nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv | sudo) forge_skip_runner "${toks[$i]}" ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      env) forge_skip_env ;;
      xargs)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            -a | -d | -E | -I | -L | -n | -P | -s | --arg-file | --delimiter | --max-lines | --max-args | --max-procs | --max-chars | --replace | --eof) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local cw="${toks[$i]}" base
  base="$(forge_basename "$cw")"

  # Opaque command word ($BD / $(which bd)) fronting a close-verb in this segment -> unverifiable -> fail
  # closed (best-effort; the $-cw gate keeps false-positives negligible — a $-command-word AND a bare
  # close-verb token in the SAME segment is not a realistic benign shape).
  case "$cw" in
    *'$'* | *'`'*)
      local _k
      for ((_k = i; _k < n; _k++)); do
        case "$(forge_unquote "${toks[$_k]}")" in
          close | done | import | supersede | duplicate) forge_bd_deny "a bd close-verb behind an opaque command word ($cw) cannot be verified"; break ;;
        esac
      done
      ;;
  esac

  [ "$base" = bd ] || return 0

  # Substitution/ANSI-C-quoting anywhere in a confirmed bd segment -> operand unknowable -> fail closed (mirror
  # the git walker). `$'...'` is added so `bd $'close'` / `bd todo $'done'` (which forge_unquote,
  # stripping only outer "..."/'...', would miss) fail closed. Verb-agnostic like the $(/`/${ arms — a bd read
  # bearing `$'...'` is denied too (consistent, near-zero realistic use).
  case "$seg" in *'$('* | *'`'* | *'${'* | *"\$'"*) forge_bd_deny "a bd command with a substituted / ANSI-C-quoted argument cannot be verified" ;; esac

  # Global-flag interposition BEFORE the subcommand (mirror the git global-flag block, lib.sh:1662-1672). The
  # bd VALUE-taking globals (--actor/--db/-C/--directory/--dolt-auto-commit) consume 2 tokens when DETACHED;
  # the glued forms (--db=x, -Cdir) and ALL boolean globals (--json/--global/-q/-v/-V/--readonly/--sandbox/...)
  # are single tokens caught by the generic -* arm. First non-flag token = the bd subcommand. Modeling the
  # value-takers precisely is REQUIRED — a missed value-taker desyncs the scan (`bd -C closed close X` would
  # else misread `closed` as the verb). Each candidate token is forge_unquote'd BEFORE the case-match, so a
  # WHOLLY-quoted verb (`bd "close" X`, `bd 'close' X`) resolves to its executed value (F1 quote-bypass fix).
  i=$((i + 1))
  local verb="" vtok
  while [ "$i" -lt "$n" ]; do
    vtok="$(forge_unquote "${toks[$i]}")"
    case "$vtok" in
      --actor | --db | --directory | -C | --dolt-auto-commit) i=$((i + 2)) ;;
      close | done | import | supersede | duplicate | update | todo) verb="$vtok"; i=$((i + 1)); break ;;
      -*) i=$((i + 1)) ;;
      *) return 0 ;;
    esac
  done
  [ -n "$verb" ] || return 0

  case "$verb" in
    close | done | import | supersede | duplicate)
      forge_bd_deny "bd $verb is a done-edge close-path and is not allowed from the agent session" ;;
    update)
      # Subcommand-GATED last-wins status scan (the over-block guard): ONLY under `update` do we look for
      # a -s/--status whose LAST value is `closed`. Gating on verb==update is why `bd list --status closed
      # --closed-after <ts>` (a LIVE harness read + an agent-allowlisted read) is NOT over-blocked. We do NOT
      # substring-match `closed` (so `bd list --closed-after <ts>` passes) and scope strictly to -s/--status.
      # The value is forge_unquote'd so a WHOLLY-quoted `-s "closed"` / `--status='closed'` is caught (F1).
      local st="" j="$i" stok
      while [ "$j" -lt "$n" ]; do
        stok="$(forge_unquote "${toks[$j]}")"
        case "$stok" in
          -s | --status) j=$((j + 1)); [ "$j" -lt "$n" ] && st="$(forge_unquote "${toks[$j]}")"; j=$((j + 1)) ;;
          --status=*) st="$(forge_unquote "${stok#--status=}")"; j=$((j + 1)) ;;
          -s?*) st="$(forge_unquote "${stok#-s}")"; j=$((j + 1)) ;;
          *) j=$((j + 1)) ;;
        esac
      done
      [ "$st" = closed ] && forge_bd_deny "bd update --status closed is a done-edge close-path and is not allowed from the agent session"
      ;;
    todo)
      # `bd todo done <id>` is a DOCUMENTED alias for `bd close <id>` (bd help:
      # "bd todo done <id> -> bd close <id>"). Subcommand-GATED first-non-flag look-ahead (mirror the update
      # arm above): after `todo` the FIRST non-flag token is the todo subcommand -> deny ONLY when it is `done`,
      # so the READ/CREATE subcommands `bd todo list` / `bd todo add ...` / bare `bd todo` are NOT over-blocked.
      # First-non-flag (not last-wins) is deliberate: `bd todo add done` (a task titled "done") stays ALLOWED
      # because `add` terminates the scan first. The no-id form `bd todo done` still denies (closes last-
      # touched, like bare `bd close`). forge_unquote'd so a wholly-quoted `bd todo "done"` is caught. The bd
      # VALUE-globals are skipped 2-token (cobra intersperses persistent flags AFTER the subcommand path:
      # `bd todo -C /x done` == a real close), which ALSO keeps `bd todo -C done list` (a dir named "done")
      # from over-blocking — the same value-taker desync guard the verb-scan carries (lib.sh:2008-2012).
      local ttok j2="$i"
      while [ "$j2" -lt "$n" ]; do
        ttok="$(forge_unquote "${toks[$j2]}")"
        case "$ttok" in
          --actor | --db | --directory | -C | --dolt-auto-commit) j2=$((j2 + 2)) ;;
          done) forge_bd_deny "bd todo done is a done-edge close-path (a documented alias for bd close) and is not allowed from the agent session" ;;
          -*) j2=$((j2 + 1)) ;;
          *) break ;;
        esac
      done
      ;;
  esac
  return 0
}

# ── gh (GitHub CLI) capability policy ────────────────────────────────────────────────────────────────
# Deny the agent's DANGEROUS gh mutation surfaces — pr merge, repo-admin, secrets, auth, workflow control,
# and gh-api write paths — while leaving every benign read/comment untouched (`gh pr view|diff|comment|
# create|list|checks`, `gh repo view|list|clone`, `gh auth status`, `gh workflow list|view`, `gh api <GET>`,
# `gh issue ...`). Mirrors forge_check_bd: a whole-command launder guard + a per-segment argv walker. This
# closes the flagship capability hole — "agents never merge / never administer" was CONVENTION-ONLY (the
# harness never CALLS `gh pr merge`; nothing stopped an agent's Bash from calling it). No door: a human
# merges/administers in a NON-agent shell or the GitHub UI, invisible to this PreToolUse hook, so there is
# nothing legitimate to open. CONCEDED (best-effort, documented): a `gh api` WRITE laundered through an
# interpreter body the walker cannot see; gh-api GET enumeration of secret NAMES via an admin endpoint.
forge_gh_deny() {
  forge_deny "$1 — the GitHub merge/admin surface is a human capability: agents open PRs and comment, never merge or administer. Bounded capability deny (no door; a human acts in a non-agent shell / the GitHub UI, invisible to this hook)."
}

# forge_check_gh <cmd> — deny the agent's DIRECT dangerous gh subcommands. Mirrors forge_check_bd.
forge_check_gh() {
  local cmd="$1" seg
  # Whole-command launder guard: a `gh <dangerous phrase>` laundered through a pipe-into-shell / eval /
  # interpreter -c body the per-segment walker cannot see into (`bash -c 'gh pr merge X'`, `eval gh repo
  # delete o/r`, `echo gh pr merge | bash`). Gate on the ADJACENT dangerous phrase so benign `gh pr view |
  # cat`, `gh pr comment ... | tee` never over-block. `gh api` is DELIBERATELY excluded here (an api GET is
  # benign and laundering it is not a mutation — api writes are caught by the per-segment walker; a laundered
  # api write is the documented conceded gap). DEFENSE-IN-DEPTH: the per-segment walker is the load-bearing
  # boundary.
  if printf '%s' "$cmd" | grep -Eq '(^|[^A-Za-z0-9_.-])gh[[:space:]]+(pr[[:space:]]+merge|repo[[:space:]]+(delete|archive|unarchive|rename|edit|set-default|deploy-key|transfer)|secret([[:space:]]|$)|auth[[:space:]]+(login|logout|token|refresh|setup-git|switch)|workflow[[:space:]]+(enable|disable|run))([^A-Za-z0-9_-]|$)'; then
    printf '%s' "$cmd" | grep -Eq '\|[[:space:]]*(sh|bash|dash|zsh|ksh|busybox|xargs|python[0-9.]*|node|perl|ruby)([[:space:]]|$)' && forge_gh_deny "a gh mutation verb piped into a shell/interpreter cannot be verified"
    printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' && forge_gh_deny "a gh mutation verb via eval cannot be verified"
    forge_interp_evalbody "$cmd" && forge_gh_deny "a gh mutation verb inside an interpreter -c/-e body cannot be verified"
  fi
  # Per-segment: split on && || ; | and a bare & (mirror forge_check_bd — protects the &-family redirects).
  while IFS= read -r seg; do
    forge_check_gh_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g; s/&>>/\x01/g; s/&>/\x02/g; s/>&/\x03/g; s/&/\n/g; s/\x03/>\&/g; s/\x02/\&>/g; s/\x01/\&>>/g')"
}

forge_check_gh_seg() {
  local seg="$1" _o
  local -a toks=()
  _o="$IFS"
  set -f
  IFS=$' \t\n' read -r -a toks <<<"$seg"
  set +f
  IFS="$_o"
  local n="${#toks[@]}"
  [ "$n" -gt 0 ] || return 0
  forge_strip_group_close
  [ "$n" -gt 0 ] || return 0

  # Reach the command word past leading grouping/keyword/VAR=val/runner/exec/env/xargs tokens — copied
  # VERBATIM from forge_check_bd_seg (shared grammar via bash dynamic scope on toks/n/i).
  local i=0
  while [ "$i" -lt "$n" ]; do
    case "${toks[$i]}" in '('* | '{'*) toks[$i]="${toks[$i]#[({]}" ;; esac
    case "${toks[$i]}" in
      '' | '(' | '{' | '((' | '!' | then | do | else | elif | while | until) i=$((i + 1)) ;;
      *=*) i=$((i + 1)) ;;
      nohup | busybox) i=$((i + 1)) ;;
      nice | stdbuf | setsid | ionice | time | command | doas | timeout | chrt | flock | strace | ltrace | fakeroot | valgrind | watch | eatmydata | taskset | chroot | setarch | numactl | setpriv | sudo) forge_skip_runner "${toks[$i]}" ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            --) i=$((i + 1)); break ;;
            -a) i=$((i + 2)) ;;
            -c | -l | -cl | -lc) i=$((i + 1)) ;;
            -*) forge_deny "exec with an unrecognized option cannot be verified — denied" ;;
            *) break ;;
          esac
        done
        ;;
      env) forge_skip_env ;;
      xargs)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            -a | -d | -E | -I | -L | -n | -P | -s | --arg-file | --delimiter | --max-lines | --max-args | --max-procs | --max-chars | --replace | --eof) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  local cw="${toks[$i]}" base
  base="$(forge_basename "$cw")"

  # NOTE — DELIBERATELY NO opaque-command-word arm (unlike forge_check_bd_seg). gh's dangerous verbs
  # (edit / delete / merge / rename / token / switch / login / …) are COMMON English words, so scanning an
  # opaque-`cw` segment (`$EDITOR merge`, `$BIN edit`, `git rebase && $VAR rename`) for them over-blocks
  # benign commands wholesale. A variable-indirection front (`GH=gh; $GH pr merge`) is therefore a CONCEDED
  # residual (documented) — the launder guard still catches the interpreter/eval/pipe forms, and this is the
  # "do not chase every obfuscation" line. We act ONLY on a command word that literally resolves to `gh`.
  [ "$base" = gh ] || return 0

  # Skip gh GLOBAL persistent flags to the first non-flag token = the command GROUP. The only value-taking
  # global is -R/--repo <owner/repo> (detached 2-token; glued -Rx / --repo=x are single -* tokens). All other
  # persistent flags (--help/--version) are booleans caught by -*. Each candidate is forge_unquote'd first
  # (a wholly-quoted group `gh "pr" merge` resolves to its executed value).
  i=$((i + 1))
  local group="" gtok
  while [ "$i" -lt "$n" ]; do
    gtok="$(forge_unquote "${toks[$i]}")"
    case "$gtok" in
      -R | --repo) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) group="$gtok"; i=$((i + 1)); break ;;
    esac
  done
  [ -n "$group" ] || return 0

  # `gh api` has NO subcommand verb — the next operand is the endpoint. Deny only a MUTATING api call: an
  # explicit write method (-X/--method POST|PUT|PATCH|DELETE), a field flag that forces POST
  # (-f/-F/--field/--raw-field/--input). A bare `gh api <endpoint>` (GET read) is ALLOWED — the reviewer/
  # agent REST read path. Known read value-takers (-H/-q/--jq/--template/-t/--hostname/--cache) skip their
  # value 2-token so a header/jq value cannot be misread as a write flag.
  if [ "$group" = api ]; then
    local j="$i" atok m
    while [ "$j" -lt "$n" ]; do
      atok="$(forge_unquote "${toks[$j]}")"
      case "$atok" in
        -X | --method)
          j=$((j + 1)); m=""; [ "$j" -lt "$n" ] && m="$(forge_unquote "${toks[$j]}")"
          case "$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]')" in POST | PUT | PATCH | DELETE) forge_gh_deny "gh api with a mutating method ($m) can merge/administer and is not allowed" ;; esac
          j=$((j + 1)) ;;
        -X*) case "$(printf '%s' "${atok#-X}" | tr '[:lower:]' '[:upper:]')" in POST | PUT | PATCH | DELETE) forge_gh_deny "gh api with a mutating method (${atok#-X}) can merge/administer and is not allowed" ;; esac; j=$((j + 1)) ;;
        --method=*) case "$(printf '%s' "${atok#--method=}" | tr '[:lower:]' '[:upper:]')" in POST | PUT | PATCH | DELETE) forge_gh_deny "gh api with a mutating method (${atok#--method=}) can merge/administer and is not allowed" ;; esac; j=$((j + 1)) ;;
        -f | -F | --field | --raw-field | --input) forge_gh_deny "gh api with a field/input body ($atok) forces a write and can merge/administer — not allowed" ;;
        -f* | -F*) forge_gh_deny "gh api with a field body ($atok) forces a write and can merge/administer — not allowed" ;;
        --field=* | --raw-field=* | --input=*) forge_gh_deny "gh api with a field/input body forces a write and can merge/administer — not allowed" ;;
        -H | --header | -q | --jq | --template | -t | --hostname | --cache) j=$((j + 2)) ;;
        *) j=$((j + 1)) ;;
      esac
    done
    return 0
  fi

  # Non-api groups: find the VERB (first non-flag token after the group), skipping any interposed flags
  # (incl. the -R/--repo value-taker). Unquote each so a wholly-quoted verb resolves to its executed value.
  local verb="" vtok
  while [ "$i" -lt "$n" ]; do
    vtok="$(forge_unquote "${toks[$i]}")"
    case "$vtok" in
      -R | --repo) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) verb="$vtok"; break ;;
    esac
  done
  [ -n "$verb" ] || return 0

  case "$group" in
    pr) case "$verb" in merge) forge_gh_deny "gh pr merge is not allowed — agents never merge; a human merges the PR" ;; esac ;;
    repo) case "$verb" in delete | archive | unarchive | rename | edit | set-default | deploy-key | transfer) forge_gh_deny "gh repo $verb is a repository-admin mutation and is not allowed" ;; esac ;;
    secret) forge_gh_deny "gh secret $verb touches repository/org secrets and is not allowed for a build agent" ;;
    auth) case "$verb" in login | logout | token | refresh | setup-git | switch) forge_gh_deny "gh auth $verb is a dangerous credential operation and is not allowed (gh auth status is allowed)" ;; esac ;;
    workflow) case "$verb" in enable | disable | run) forge_gh_deny "gh workflow $verb controls CI execution and is not allowed" ;; esac ;;
  esac
  return 0
}
forge_check_git() {
  local cmd="$1" seg
  while IFS= read -r seg; do
    forge_check_git_seg "$seg"
  done <<<"$(printf '%s' "$cmd" | sed -E 's/(\&\&|\|\||;|\|)/\n/g')"
}

# ── Session-floor witness — lib.sh SPLICE PAYLOAD ────────────────────────────────────────────────────
# Human-spliced VERBATIM into .claude/hooks/lib.sh (appended after forge_check_push).
# SOURCED, not executed. lib.sh discipline: no set -e/-u, defensive reads, loud named refusals.
#
# THE PROBLEM (the off-root launch hole, claude-code#12962 / PROBE-A.3): a session launched from a
# cwd without the project .claude/ loads NO deny floor, and nothing proves the floor loaded in THIS
# session before a privileged host-side op (intake convert, run-task finish) runs.
# THE MECHANISM (probe-proven): the SessionStart hook (session-start-witness.sh) hash-pins the deny
# floor into .harness/session-floor.<session_id>.json; the privileged op resolves its own session id
# (exported via CLAUDE_ENV_FILE at SessionStart, PROBE-A.4), reads the witness, and recomputes the
# hash live. ABSENCE of the witness is what gates — at the privileged op, never at SessionStart.

# forge_floor_hash <root> — THE one hash recipe, shared by the SessionStart hook (mint) and
# forge_witness_verify (check) so the two sites cannot diverge (the _intake_fr_hash lesson).
# FIXED ORDER: (1) pre-tool-use-deny.sh bytes, (2) lib.sh bytes, (3) the canonical PreToolUse stanza
# of settings.json, normalized by `jq -cS` — whitespace/key-order edits do not false-drift, while
# ARRAY order is preserved (hook order inside the PreToolUse array is semantically load-bearing).
# FAIL CLOSED: any input missing/unreadable, stanza absent, or jq absent -> return 1, no output.
# Each input is checked BEFORE the pipe — a bare `cat ... | sha256sum` would silently hash a
# partial floor on a missing file (fail-open), so existence is asserted first.
forge_floor_hash() {
  local root="$1" deny lib witness settings stanza sstanza
  [ -n "$root" ] || return 1
  deny="$root/.claude/hooks/pre-tool-use-deny.sh"
  lib="$root/.claude/hooks/lib.sh"
  # Witness-hardening (R1): the MINT script and the SessionStart stanza are now SELF-VERIFIED
  # inputs, not merely floor-protected. A coverage probe proved the asymmetry was real (editing
  # either left the OLD hash unchanged); folding them closes the only floor-disable residual that was honor-
  # on-deny-floor rather than self-hashed. FIXED ORDER (mint and verify share this recipe): deny.sh, lib.sh,
  # the mint-script bytes, then the PreToolUse stanza, then the SessionStart stanza. NOTE: this recipe change
  # invalidates any pre-existing witness; the next SessionStart re-mints — self-healing within one session.
  witness="$root/.claude/hooks/session-start-witness.sh"
  settings="$root/.claude/settings.json"
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$deny" ] && [ -r "$deny" ] || return 1
  [ -f "$lib" ] && [ -r "$lib" ] || return 1
  [ -f "$witness" ] && [ -r "$witness" ] || return 1
  [ -f "$settings" ] && [ -r "$settings" ] || return 1
  stanza="$(jq -cS '.hooks.PreToolUse // empty' "$settings" 2>/dev/null)"
  [ -n "$stanza" ] || return 1
  sstanza="$(jq -cS '.hooks.SessionStart // empty' "$settings" 2>/dev/null)"
  [ -n "$sstanza" ] || return 1
  { cat "$deny" "$lib" "$witness" && printf '%s' "$stanza" && printf '%s' "$sstanza"; } | sha256sum | cut -d' ' -f1
}

# Commit-to-main guard: is the git pre-commit guard INSTALLED at <root>? — does git's RESOLVED hooks dir
# canonicalize to <root>/harness/githooks? realpath-canonical on BOTH sides (cd + pwd -P resolves
# symlinks and .., the same rigor as the work_root / git-common-dir compares): an ABSOLUTE-but-correct
# hooks path PASSES, a SUFFIX-matching-but-wrong one FAILS — never a raw string compare against the
# config value. Fail-closed: unset / wrong / missing dir / non-git repo => return 1. The SessionStart
# witness calls this and REFUSES to write the witness when it fails, so the privileged ops fail-closed
# on witness ABSENCE — making the git-hook tier's install mechanically guaranteed, not honor-based.
forge_hookspath_ok() {
  local root="$1" live want
  [ -n "$root" ] || return 1
  # FOLD #10: neutralize the fsmonitor axis defensively (DiD). NOTE: `-c core.hooksPath=/dev/null`
  # is DELIBERATELY NOT added here — `rev-parse --git-path hooks` RESOLVES core.hooksPath, so overriding it
  # to /dev/null would corrupt the very value this check verifies (proven: it returns /dev/null). `rev-parse`
  # does not refresh the index, so the fsmonitor exec is not a live vector here — this is pure defense-in-depth.
  live="$(git -C "$root" -c core.fsmonitor= rev-parse --git-path hooks 2>/dev/null)" || return 1
  [ -n "$live" ] || return 1
  case "$live" in /*) : ;; *) live="$root/$live" ;; esac
  live="$(cd "$live" 2>/dev/null && pwd -P)" || return 1
  want="$(cd "$root/harness/githooks" 2>/dev/null && pwd -P)" || return 1
  [ -n "$live" ] && [ -n "$want" ] && [ "$live" = "$want" ] || return 1
  # POINTER-correct is necessary but NOT sufficient — an EMPTY harness/githooks
  # (config set, no hook file) lets the witness MINT while the git pre-commit tier is inert. Require the
  # guard to be actually PRESENT: an executable pre-commit under the resolved hooks dir. Absence => fail
  # closed (the witness then refuses, so privileged ops fail-closed on a pointed-at-but-empty hooks dir).
  [ -x "$live/pre-commit" ]
}

# forge_witness_sid_ok <sid> — the session id lands in a FILENAME (witness path) and, hook-side, in
# an env file: it is attacker-influenced input. Strict charset, fail closed.
# Whole-STRING match (case glob), not `grep -Eq '^…$'`: grep anchors PER LINE, so a multiline sid
# whose every byte fails the charset on one line still passes if any OTHER line is clean — a
# single-quote-bearing newline sid would then break out of the single-quoted CLAUDE_ENV_FILE export.
# The negated class rejects newline/space/quote/slash/unicode anywhere; the empty arm fails closed.
forge_witness_sid_ok() { case "$1" in '' | *[!A-Za-z0-9-]*) return 1 ;; *) return 0 ;; esac; }

# Loud named refusal to stderr (reason tag first, so tests and humans can key on it).
_forge_witness_refuse() { printf 'agentic-builder-forge witness: REFUSED [%s] — %s\n' "$1" "$2" >&2; }

# forge_witness_verify [root] — STRICT verifier: returns 0 ONLY when a this-session witness exists
# AND its recorded floor_hash matches the live floor at <root> (default: the main checkout root).
# The splices pass "$ROOT" explicitly; tests pass a throwaway root. Refusal paths, each named:
#   witness-refused-no-session-id     CLAUDE_SESSION_ID unset — this session cannot self-identify
#                                     (off-root launch, or the SessionStart hook is not deployed)
#   witness-refused-bad-session-id    sid fails ^[A-Za-z0-9-]+$ (filename-injection surface)
#   witness-refused-no-root           cannot resolve the floor root / harness dir
#   witness-refused-absent            no session-floor.<sid>.json — THE off-root signal (PROBE-A.3)
#   witness-refused-unreadable        witness present but floor_hash unreadable
#   witness-refused-session-mismatch  recorded session_id != CLAUDE_SESSION_ID (defense in depth
#                                     beyond the filename encoding)
#   witness-refused-floor-unhashable  live floor files missing/unreadable at <root>
#   witness-refused-floor-drift       recorded != live hash (both printed)
forge_witness_verify() {
  local root="${1:-}" sid="${CLAUDE_SESSION_ID:-}" hd wf rec_sid rec live
  if [ -z "$sid" ]; then
    _forge_witness_refuse witness-refused-no-session-id "CLAUDE_SESSION_ID is unset — this session cannot self-identify; no SessionStart witness ran here (off-root launch, or hook not deployed)"
    return 1
  fi
  if ! forge_witness_sid_ok "$sid"; then
    _forge_witness_refuse witness-refused-bad-session-id "CLAUDE_SESSION_ID fails ^[A-Za-z0-9-]+\$ (sid: $sid)"
    return 1
  fi
  [ -n "$root" ] || root="$(forge_main_root 2>/dev/null)"
  if [ -z "$root" ]; then
    _forge_witness_refuse witness-refused-no-root "cannot resolve the floor root (no argument and forge_main_root failed)"
    return 1
  fi
  hd="$(forge_harness_dir 2>/dev/null)"
  if [ -z "$hd" ]; then
    _forge_witness_refuse witness-refused-no-root "cannot resolve the harness dir"
    return 1
  fi
  wf="$hd/session-floor.$sid.json"
  if [ ! -f "$wf" ]; then
    _forge_witness_refuse witness-refused-absent "no session-floor witness for THIS session ($wf) — the deny floor was not proven loaded in this session (off-root launch?)"
    return 1
  fi
  rec_sid="$(jq -r '.session_id // empty' "$wf" 2>/dev/null)"
  rec="$(jq -r '.floor_hash // empty' "$wf" 2>/dev/null)"
  if [ -z "$rec" ]; then
    _forge_witness_refuse witness-refused-unreadable "witness $wf carries no readable floor_hash"
    return 1
  fi
  if [ "$rec_sid" != "$sid" ]; then
    _forge_witness_refuse witness-refused-session-mismatch "witness records session_id=$rec_sid but this session is $sid"
    return 1
  fi
  live="$(forge_floor_hash "$root")"
  if [ -z "$live" ]; then
    _forge_witness_refuse witness-refused-floor-unhashable "cannot hash the live floor at $root (deny hook / lib.sh / PreToolUse stanza missing or unreadable)"
    return 1
  fi
  if [ "$rec" != "$live" ]; then
    _forge_witness_refuse witness-refused-floor-drift "floor hash drift: witnessed=$rec live=$live — the floor changed since SessionStart, or a different floor loaded"
    return 1
  fi
  return 0
}

# forge_root_ever_witnessed [root] — has a SessionStart witness EVER been minted for this checkout (is the
# witness deployed + proven HERE)? 0 if any session-floor.*.json exists in the harness dir. Distinguishes a
# witness-ENABLED checkout (where a verify failure is a real signal) from a never-witnessed legacy checkout
# (no SessionStart hook — degrade gracefully rather than brick it). Witness-hardening (R1).
forge_root_ever_witnessed() {
  local hd f
  hd="$(forge_harness_dir 2>/dev/null)" || return 1
  [ -n "$hd" ] || return 1
  for f in "$hd"/session-floor.*.json; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# forge_floor_under_active_edit [root] — is a HASHED floor file under ACTIVE human edit, i.e. an UNCOMMITTED
# working-tree diff vs HEAD (the SANCTIONED mid-session floor-development signal)? 0 = yes (warn, do not brick
# the work). Covers exactly forge_floor_hash's tracked file inputs. FAIL-CLOSED: if the diff cannot be
# determined (not a git repo / git error), return 1 (NOT active edit) so the gate HARD-refuses — the safe
# boundary direction (refuse when the sanctioned-edit signal is unprovable). Witness-hardening (R1).
forge_floor_under_active_edit() {
  local root="$1"
  [ -n "$root" ] || root="$(forge_main_root 2>/dev/null)" || return 1
  [ -n "$root" ] || return 1
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  # `git diff --quiet HEAD -- <paths>`: rc 0 = no diff (clean), rc 1 = a real diff (active edit), rc >1 = a
  # git ERROR (unborn repo / unresolvable HEAD / rc-128). Fail-closed-total: ANY
  # non-0/1 rc fail-closes to NOT-active so the gate HARD-refuses — the discriminator's fail-closed-on-
  # uncertainty contract is TOTAL, covering git-diff errors and not only the not-a-git-repo guard above.
  # The `case $?` form (NOT an `if … then return 1; fi; return 0` fall-through, which treated an error rc
  # like a real diff and warned) is what enforces it.
  # FOLD #10: neutralize git's hook-exec axes (mirrors forge_git, sandbox-lib.sh:23) — a planted
  # core.fsmonitor in the RW-bound main .git/config would otherwise EXEC host-side when this bare diff
  # refreshes the index (the live witness-gate vector). `git diff` does not return the hooks path, so the
  # core.hooksPath=/dev/null override is safe here AND closes the hooksPath-redirect axis too.
  git -C "$root" -c core.fsmonitor= -c core.hooksPath=/dev/null diff --quiet HEAD -- \
    .claude/hooks/pre-tool-use-deny.sh \
    .claude/hooks/lib.sh \
    .claude/hooks/session-start-witness.sh \
    .claude/settings.json 2>/dev/null
  case $? in
    0) return 1 ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# forge_witness_gate [root] — the wrapper the privileged entrypoints call. On a verify FAILURE it decides
# refuse-to-proceed (rc 1, caller die()s) vs warn-and-proceed (rc 0):
#   FORGE_UNATTENDED=1   : ALWAYS HARD — the agent/headless path never runs a privileged op on an unproven
#                          floor. The discriminator below does NOT apply.
#   attended (otherwise) : CONDITIONAL-HARD (witness-hardening, R1). The witness is the
#                          boundary, so it must FIRE on the attended path too — WITHOUT bricking legitimate
#                          mid-session floor development. The SANCTIONED-vs-UNSANCTIONED discriminator is the
#                          uncommitted-enforce-file-diff (NOT a cosmetic attended/unattended split):
#                            - witness-enabled checkout (a prior witness exists) AND a CLEAN floor (no
#                              uncommitted enforce-file diff) -> the drift/disable/off-root is UNSANCTIONED
#                              -> HARD REFUSE (the boundary fires; a clean session must not run a drifted floor).
#                            - floor under ACTIVE edit (uncommitted enforce-file diff) -> sanctioned floor
#                              development -> WARN (do not brick the work that edits the floor).
#                            - never-witnessed legacy checkout (no prior witness) -> WARN (graceful degrade).
forge_witness_gate() {
  local root="${1:-}"
  forge_witness_verify "$root" && return 0
  if [ "${FORGE_UNATTENDED:-0}" = "1" ]; then
    printf 'agentic-builder-forge witness: HARD REFUSAL — FORGE_UNATTENDED=1 and the session-floor witness did not verify (reason above). A privileged operation must not run in a session where the deny floor is not proven loaded (fx-v0w).\n' >&2
    return 1
  fi
  if forge_root_ever_witnessed "$root" && ! forge_floor_under_active_edit "$root"; then
    printf 'agentic-builder-forge witness: HARD REFUSAL (attended, clean witness-enabled session) — the witness did not verify (reason above) and the floor is NOT under active edit (no uncommitted enforce-file diff). An UNSANCTIONED floor drift/disable/off-root must not proceed (fx-v0w conditional-hard). If you ARE mid-floor-development the edit shows as an uncommitted diff and this becomes a warning; otherwise re-mint by restarting the session on a clean floor.\n' >&2
    return 1
  fi
  printf 'agentic-builder-forge witness: WARNING (attended) — the witness did not verify (reason above); proceeding because the floor is under active edit (uncommitted enforce-file diff = sanctioned mid-session development) or this checkout has never minted a witness. This is a HARD refusal under FORGE_UNATTENDED=1 and on a clean witness-enabled session.\n' >&2
  return 0
}
