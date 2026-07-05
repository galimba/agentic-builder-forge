#!/usr/bin/env bash
# harness/vault.sh — OPTIONAL, READ-ONLY Vault path resolver (P7).
#
# The Vault is a sibling knowledge repo (human-curated context/memory), read-only to the entire Forge by
# CONVENTION. This resolver is the read-side seam: it prints configured vault LOCATIONS so an agent can
# consult them with its OWN Read/Grep tools. It NEVER reads vault content, NEVER writes anything, NEVER
# returns a verdict, and is NEVER invoked by any gate / reconcile / branch / floor path. The floor makes
# no vault claim (tests/boundary/fold28); vault read-only-ness is the target's / OS container's concern.
#
#   vault.sh paths     print each configured vault's ABSOLUTE, existing directory path (one per line)
#   vault.sh doctor    a "configured N; present M" summary (for doctor.sh; info only, never a verdict)
#
# Config: FORGE_VAULT_CONFIG or <root>/harness/vault.config (OPTIONAL — absent means NO vault, not an error).
#   <name>=/absolute/path/to/read-only/knowledge/repo
# ABSOLUTE paths only: a relative / '..'-bearing / non-directory entry is SKIPPED (named to stderr). A
# relative vault write still denies via the deny hook's general '..' rule; an absolute vault path is out
# of forge scope. This script only READS $CFG and prints — it has no write path by construction.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CFG="${FORGE_VAULT_CONFIG:-$ROOT/harness/vault.config}"
TAB="$(printf '\t')"

# Emit "name<TAB>path" for each syntactically-valid ABSOLUTE entry; skip + warn on the rest. Read-only.
_vault_entries() {
  [ -f "$CFG" ] || return 0
  local line name path
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"   # tolerate a CRLF-authored config (strip a trailing CR)
    case "$line" in '' | \#*) continue ;; esac
    [ "${line#*=}" != "$line" ] || { printf 'vault: skipping malformed line (no name=path): %s\n' "$line" >&2; continue; }
    name="${line%%=*}"
    path="${line#*=}"
    [ -n "$name" ] || { printf 'vault: skipping entry with empty name: %s\n' "$line" >&2; continue; }
    [ -n "$path" ] || { printf 'vault: skipping entry %s with empty path\n' "$name" >&2; continue; }
    case "$path" in
      /*) : ;;
      *) printf 'vault: skipping non-absolute path for %s: %s\n' "$name" "$path" >&2; continue ;;
    esac
    case "$path" in *..*) printf 'vault: skipping %s — path contains "..": %s\n' "$name" "$path" >&2; continue ;; esac
    printf '%s%s%s\n' "$name" "$TAB" "$path"
  done <"$CFG"
}

cmd_paths() {
  local name path
  while IFS="$TAB" read -r name path; do
    [ -n "$path" ] || continue
    if [ -d "$path" ]; then
      printf '%s\n' "$path"
    else
      printf 'vault: configured vault %s is not an existing directory (skipped): %s\n' "$name" "$path" >&2
    fi
  done < <(_vault_entries)
}

cmd_doctor() {
  local configured=0 present=0 total=0 skipped name path line
  # total = non-empty, non-comment DATA lines; skipped = data lines dropped as malformed/relative/'..' so a
  # typo'd entry is visible in the count (the per-line reasons go to stderr via _vault_entries).
  if [ -f "$CFG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in '' | \#*) continue ;; esac
      total=$((total + 1))
    done <"$CFG"
  fi
  while IFS="$TAB" read -r name path; do
    [ -n "$name" ] || continue
    configured=$((configured + 1))
    [ -d "$path" ] && present=$((present + 1))
  done < <(_vault_entries 2>/dev/null)
  skipped=$((total - configured))
  if [ "$total" -eq 0 ]; then
    printf 'vault: none (optional)\n'
  elif [ "$skipped" -gt 0 ]; then
    printf 'vault: configured %s; present %s; skipped %s (malformed/relative/.. — run `harness/vault.sh doctor` to see them)\n' "$configured" "$present" "$skipped"
  else
    printf 'vault: configured %s; present %s\n' "$configured" "$present"
  fi
}

case "${1:-}" in
  paths) cmd_paths ;;
  doctor) cmd_doctor ;;
  -h | --help | help) printf 'usage: vault.sh {paths|doctor} — optional read-only vault path resolver\n' ;;
  '') printf 'usage: vault.sh {paths|doctor}\n' >&2; exit 2 ;;
  *) printf 'vault.sh: unknown subcommand: %s (usage: vault.sh {paths|doctor})\n' "$1" >&2; exit 2 ;;
esac
