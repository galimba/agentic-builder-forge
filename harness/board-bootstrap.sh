#!/usr/bin/env bash
# harness/board-bootstrap.sh — oversight board: idempotent STRUCTURE ensure + board.config emit.
#
# The board is a READ-ONLY projection of Beads (Agent B). This defines/verifies ONLY the GitHub Project v2
# STRUCTURE (project, fields, single-select options, visibility) and emits the ID manifest
# (harness/board.config) that board-sync.sh consumes. CONTRACT-WIDTH-INDEPENDENT: it knows nothing about
# which beads `run-task.sh board --json` emits — only the board's shape. Idempotent: a re-run against an
# already-correct board makes ZERO mutations and re-emits board.config. Never writes Beads / .beads/.
#
#   ./harness/board-bootstrap.sh ensure   # find-or-create project+fields+options, set private, emit config (default)
#   ./harness/board-bootstrap.sh verify   # read-only to GitHub: FAIL if missing/wrong; still emit board.config
#
# TOKEN: Projects v2 needs the `project` OAuth scope. The default GITHUB_TOKEN often lacks it, so gh runs
# with GITHUB_TOKEN/GH_TOKEN UNSET (falls back to the scoped keyring token); override BOARD_GH_KEEP_TOKEN=1.
set -uo pipefail

OWNER="${BOARD_OWNER:?board-bootstrap: set BOARD_OWNER to your GitHub org or user (see harness/board.config.example)}"
TITLE="${BOARD_TITLE:-Beads Index — Oversight (read-only)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${BOARD_CONFIG:-$HERE/board.config}"
MODE="${1:-ensure}"

die() { printf 'board-bootstrap: %s\n' "$1" >&2; exit 1; }
[ "$MODE" = ensure ] || [ "$MODE" = verify ] || die "usage: board-bootstrap.sh {ensure|verify}"
command -v gh >/dev/null 2>&1 || die "gh not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
gh_() { if [ "${BOARD_GH_KEEP_TOKEN:-0}" = 1 ]; then gh "$@"; else env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; fi; }

# ---- EXPECTED STRUCTURE (the only place GitHub-side names/options live) ---------------------------
EXPECTED_FIELDS=( "Bead ID|TEXT" "Bead Assignee|TEXT" "Blocked-by|TEXT" "Priority|SINGLE_SELECT" )
STATUS_OPTIONS="Backlog,Ready,In progress,In review,Blocked,Done"
STATUS_COLORS="GRAY,GREEN,YELLOW,ORANGE,RED,PURPLE"
PRIORITY_OPTIONS="P0,P1,P2,P3,Unspecified"
PRIORITY_COLORS="RED,ORANGE,YELLOW,BLUE,GRAY"

fl=""                                            # cached field-list json (refreshed after each mutation)
refresh_fl() { fl="$(gh_ project field-list "$NUM" --owner "$OWNER" --limit 100 --format json)" || die "field-list failed"; }
field_id()  { printf '%s' "$fl" | jq -r --arg n "$1" 'first(.fields[]|select(.name==$n)|.id)//empty'; }
field_opts(){ printf '%s' "$fl" | jq -r --arg n "$1" 'first(.fields[]|select(.name==$n)|(.options//[])|map(.name)|join(","))'; }
opt_id()    { printf '%s' "$fl" | jq -r --arg f "$1" --arg o "$2" 'first(.fields[]|select(.name==$f)|.options[]|select(.name==$o)|.id)//empty'; }

# Reshape a single-select field's options to exactly <csv> (REPLACES). Works for built-in Status + custom.
ensure_select_options() { # <field_name> <csv_options> <csv_colors>
  local name="$1" want="$2" colors="$3" id now names cols opts="" i oldifs
  id="$(field_id "$name")"; [ -n "$id" ] || die "field '$name' not found for option-reshape"
  now="$(field_opts "$name")"
  [ "$now" = "$want" ] && return 0
  [ "$MODE" = verify ] && die "verify: '$name' options are [$now], expected [$want]"
  echo "→ setting '$name' options → $want"
  oldifs="$IFS"; IFS=','; read -r -a names <<<"$want"; read -r -a cols <<<"$colors"; IFS="$oldifs"
  for i in "${!names[@]}"; do
    [ -n "$opts" ] && opts+=", "
    opts+="{name: $(jq -nc --arg n "${names[$i]}" '$n'), color: ${cols[$i]:-GRAY}, description: \"\"}"
  done
  gh_ api graphql -f query="mutation { updateProjectV2Field(input: {fieldId: \"$id\", singleSelectOptions: [$opts]}) { projectV2Field { ... on ProjectV2SingleSelectField { id } } } }" >/dev/null \
    || die "reshape '$name' options failed"
  refresh_fl
}

# ---- 1. find-or-create the project ---------------------------------------------------------------
plist="$(gh_ project list --owner "$OWNER" --format json 2>&1)" || die \
  "cannot list projects for '$OWNER' — does the token have the 'project' scope? fix: gh auth refresh -s project,read:project
   gh said: $plist"
proj="$(printf '%s' "$plist" | jq -c --arg t "$TITLE" 'first(.projects[]|select(.title==$t))//empty')"
if [ -z "$proj" ]; then
  [ "$MODE" = verify ] && die "verify: project '$TITLE' not found under '$OWNER'"
  proj="$(gh_ project create --owner "$OWNER" --title "$TITLE" --format json | jq -c '{number,id}')" || die "project create failed"
  echo "→ created project '$TITLE'"
fi
NUM="$(printf '%s' "$proj" | jq -r '.number')"
NODE="$(printf '%s' "$proj" | jq -r '.id')"
[ -n "$NUM" ] && [ -n "$NODE" ] || die "could not resolve project number/node id"

# ---- 2. visibility: PRIVATE (org projects default private; belt-and-suspenders, non-fatal) --------
[ "$MODE" = ensure ] && { gh_ project edit "$NUM" --owner "$OWNER" --visibility PRIVATE >/dev/null 2>&1 || echo "  warn: could not set PRIVATE (continuing)" >&2; }

# ---- 3. ensure custom fields exist ---------------------------------------------------------------
refresh_fl
for spec in "${EXPECTED_FIELDS[@]}"; do
  name="${spec%%|*}"; dtype="${spec##*|}"
  if [ -z "$(field_id "$name")" ]; then
    [ "$MODE" = verify ] && die "verify: field '$name' missing"
    echo "→ creating field '$name' ($dtype)"
    if [ "$dtype" = SINGLE_SELECT ]; then
      gh_ project field-create "$NUM" --owner "$OWNER" --name "$name" --data-type SINGLE_SELECT --single-select-options "$PRIORITY_OPTIONS" >/dev/null || die "field-create $name failed"
    else
      gh_ project field-create "$NUM" --owner "$OWNER" --name "$name" --data-type "$dtype" >/dev/null || die "field-create $name failed"
    fi
    refresh_fl
  fi
done

# ---- 4. ensure single-select option sets (built-in Status + custom Priority) ----------------------
ensure_select_options "Status"   "$STATUS_OPTIONS"   "$STATUS_COLORS"
ensure_select_options "Priority" "$PRIORITY_OPTIONS" "$PRIORITY_COLORS"

# ---- 5. emit board.config (the ID manifest board-sync.sh consumes) -------------------------------
refresh_fl
emit() { printf '%s="%s"\n' "$1" "$2" >>"$OUT"; }
: >"$OUT"
printf '# board.config — EMITTED by board-bootstrap.sh (%s, mode=%s). Consumed by board-sync.sh.\n' "$(date -u +%FT%TZ)" "$MODE" >>"$OUT"
printf '# DO NOT hand-edit; re-run board-bootstrap.sh to regenerate. Node ids are not secret.\n' >>"$OUT"
emit BOARD_OWNER             "$OWNER"
emit BOARD_PROJECT_NUMBER    "$NUM"
emit BOARD_PROJECT_NODE_ID   "$NODE"
emit BOARD_FIELD_TITLE         "$(field_id Title)"
emit BOARD_FIELD_STATUS        "$(field_id Status)"
emit BOARD_FIELD_BEAD_ID       "$(field_id 'Bead ID')"
emit BOARD_FIELD_BEAD_ASSIGNEE "$(field_id 'Bead Assignee')"
emit BOARD_FIELD_BLOCKED_BY    "$(field_id 'Blocked-by')"
emit BOARD_FIELD_PRIORITY      "$(field_id Priority)"
oldifs="$IFS"; IFS=','
for o in $STATUS_OPTIONS;   do emit "BOARD_OPT_STATUS_$(printf '%s' "$o" | tr '[:lower:] ' '[:upper:]_')" "$(opt_id Status "$o")"; done
for o in $PRIORITY_OPTIONS; do emit "BOARD_OPT_PRIORITY_$(printf '%s' "$o" | tr '[:lower:] ' '[:upper:]_')" "$(opt_id Priority "$o")"; done
IFS="$oldifs"
echo "✓ board.config written: $OUT  (project #$NUM, mode=$MODE)"
