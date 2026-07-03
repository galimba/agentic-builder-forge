#!/usr/bin/env bash
# ISOLATION GUARD (load-bearing primitive). Makes the live floor UNREACHABLE by
# construction for the whole container boundary harness. Resolves the FINAL mount TARGETS (realpath —
# symlinks + ..), not just the source= strings, so neither a FORGE_MAIN_ROOT that points back into the
# live repo NOR a clone-relative path that is itself a symlink into the live tree can slip a mount onto
# $ROOT/.claude. "The path can be spelled to escape" — closed at the guard, the way the floor closed it.
#
# forge_assert_isolated <live_root> <forge_main_root> <manifest>   -> rc 0 isolated; rc 3 BREACH (fail closed)
forge_assert_isolated() {
  local live_root="$1" fmr="$2" manifest="$3" live mine bad_src sub tgt rt
  live="$(realpath "$live_root" 2>/dev/null)"
  mine="$(realpath "$fmr" 2>/dev/null)"
  [ -n "$live" ] && [ -n "$mine" ] || { echo "FATAL ISOLATION: unresolved roots (live=$live mine=$mine)"; return 3; }
  # (case i) FORGE_MAIN_ROOT — AFTER realpath (resolves symlinks + ..) — must be OUTSIDE the live repo.
  case "$mine/" in "$live"/*|"$live"/) echo "FATAL ISOLATION BREACH: FORGE_MAIN_ROOT realpath ($mine) is inside the live repo ($live)"; return 3;; esac
  # the manifest may mount ONLY ${localEnv:FORGE_MAIN_ROOT}/${localWorkspaceFolder} sources — any literal
  # absolute 'source=' could name the live tree directly -> fail closed on the string.
  bad_src="$(grep -oE 'source=[^,"]+' "$manifest" 2>/dev/null | grep -vE 'source=\$\{(localEnv:FORGE_MAIN_ROOT|localWorkspaceFolder)\}' || true)"
  [ -z "$bad_src" ] || { echo "FATAL ISOLATION BREACH: manifest names a non-FORGE_MAIN_ROOT source: $bad_src"; return 3; }
  # (case ii) resolve the ACTUAL mount TARGETS — a clone-relative path may itself be a symlink into the
  # live tree, and a bind mount FOLLOWS it. Assert each realpaths to STAY inside FORGE_MAIN_ROOT.
  for sub in harness .claude .claude/hooks .git .git/hooks; do
    tgt="$fmr/$sub"; [ -e "$tgt" ] || continue
    rt="$(realpath "$tgt" 2>/dev/null)"
    case "$rt/" in
      "$mine"/*) : ;;
      *) echo "FATAL ISOLATION BREACH: mount target '$sub' realpaths to $rt (outside FORGE_MAIN_ROOT $mine)"; return 3;;
    esac
  done
  echo "  ISOLATION OK: live floor $live/.claude UNREACHABLE — FORGE_MAIN_ROOT=$mine (outside live repo); source strings + realpath'd targets all inside it"
  return 0
}
