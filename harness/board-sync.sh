#!/usr/bin/env bash
# harness/board-sync.sh — project Beads onto the read-only oversight board.
#
# ONE-WAY, Beads-wins, idempotent. The board is an INDEX over Beads; this regenerates it from the
# contract. The ONLY Beads-derived input is `run-task.sh board --json` (Agent A's single derivation
# site). This script NEVER invokes `bd` and NEVER touches `.beads/` — mechanically certified by
# tests/board-sync/readonly-gate.sh (no raw `bd`, no `.beads/` path in executable code). Defense in
# depth: the vault-class `.beads/` deny-hook blocks any write there regardless. (`bd --readonly` is the
# bd-level lever for the bd-invoking layer — run-task.sh / worker sandboxes — not used here: we call no bd.)
#
#   ./harness/board-sync.sh sync       # upsert + archive-on-absence + stamp digest   (WRITES the board)
#   ./harness/board-sync.sh dry-run    # compute + print the plan; NO writes
#   ./harness/board-sync.sh check      # plan + digest vs last sync; report drift; NO writes (exit 1 on drift)
#
# Archive semantics (A): absent from `board --json` ⇒ deleted OR closed-beyond-window ⇒ archive (both).
# The all-closed manifest that would distinguish them is deferred. closed→Done; Done order is
# arbitrary (closed_at not projected). Reserved-name board fields: Status (built-in), Bead Assignee.
set -uo pipefail

MODE="${1:-sync}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CFG="${BOARD_CONFIG:-$HERE/board.config}"
STATE="${BOARD_SYNC_STATE:-$ROOT/.harness/board-sync-state.json}"

die() { printf 'board-sync: %s\n' "$1" >&2; exit 1; }
case "$MODE" in sync | dry-run | check) ;; *) die "usage: board-sync.sh {sync|dry-run|check}" ;; esac
command -v gh >/dev/null 2>&1 || die "gh not found"
command -v jq >/dev/null 2>&1 || die "jq not found"
if command -v sha256sum >/dev/null 2>&1; then SHACMD="sha256sum"; else SHACMD="shasum -a 256"; fi
[ -f "$CFG" ] || die "missing $CFG — run ./harness/board-bootstrap.sh ensure first"
# shellcheck disable=SC1090
. "$CFG"
: "${BOARD_OWNER:?board.config}" "${BOARD_PROJECT_NUMBER:?}" "${BOARD_PROJECT_NODE_ID:?}"

# gh with the project-scoped token (default GITHUB_TOKEN often lacks `project`); BOARD_GH_KEEP_TOKEN=1 in tests.
gh_() { if [ "${BOARD_GH_KEEP_TOKEN:-0}" = 1 ]; then gh "$@"; else env -u GITHUB_TOKEN -u GH_TOKEN gh "$@"; fi; }

# ---- 1. the contract — the ONLY Beads-derived input ----------------------------------------------
read_contract() {
  if [ -n "${BOARD_JSON_FILE:-}" ]; then cat "$BOARD_JSON_FILE"        # test seam: a board --json snapshot
  else "$ROOT/harness/run-task.sh" board --json 2>/dev/null; fi
}
contract="$(read_contract)" || die "could not read the board contract"
printf '%s' "$contract" | jq -e 'type=="array"' >/dev/null 2>&1 || die "contract is not a JSON array"

# ---- 2. fail-loud schema validation (catches silent mismap / shape drift) ------------------------
bad="$(printf '%s' "$contract" | jq -r '.[] | select((has("id") and has("title") and has("status") and has("ready") and has("priority") and has("blockers") and has("assignee")) | not) | (.id // "<no-id>")')"
[ -z "$bad" ] || die "contract record(s) missing a required key: $bad"
bad="$(printf '%s' "$contract" | jq -r '.[] | select(.status as $s | ["open","in_progress","in_review","blocked","closed"] | index($s) | not) | "\(.id):\(.status)"')"
[ -z "$bad" ] || die "contract has an unknown status (schema drift?): $bad"
bad="$(printf '%s' "$contract" | jq -r '.[] | select(((.ready|type)!="boolean") or ((.blockers|type)!="array") or (((.priority|type) as $t | $t!="number" and $t!="null"))) | .id')"
[ -z "$bad" ] || die "contract has bad field type(s) on: $bad"
dup="$(printf '%s' "$contract" | jq -r '[.[].id] | group_by(.)[] | select(length>1)[0]')"
[ -z "$dup" ] || die "contract has a duplicate Bead id: $dup"

# ---- 3. desired projection: lanes + field values (deterministic, sorted by id) -------------------
desired="$(printf '%s' "$contract" | jq -c '
  (map({(.id): .status}) | add) as $st
  | def open_blockers: [ .blockers[]? | select( ($st[.]) as $s | $s != null and $s != "closed" ) ];
    map({
      id, title,
      lane: ( if .status=="closed"     then "Done"
              elif .status=="in_review" then "In review"
              elif (.status=="blocked" or (open_blockers|length) > 0) then "Blocked"
              elif .status=="in_progress" then "In progress"
              elif .ready then "Ready"
              else "Backlog" end ),
      prio: ( if .priority==null then "Unspecified" elif .priority<=0 then "P0" elif .priority==1 then "P1" elif .priority==2 then "P2" else "P3" end ),
      assignee: (.assignee // ""),
      blocked_by: (.blockers | sort | join(", "))
    })
  | sort_by(.id)
')"
digest="$(printf '%s' "$desired" | jq -S -c '.' | $SHACMD | cut -d' ' -f1)"

# lane/priority option-id from board.config (fail-loud if the manifest is stale)
status_opt() { case "$1" in
  Backlog) printf '%s' "$BOARD_OPT_STATUS_BACKLOG" ;; Ready) printf '%s' "$BOARD_OPT_STATUS_READY" ;;
  "In progress") printf '%s' "$BOARD_OPT_STATUS_IN_PROGRESS" ;; "In review") printf '%s' "$BOARD_OPT_STATUS_IN_REVIEW" ;;
  Blocked) printf '%s' "$BOARD_OPT_STATUS_BLOCKED" ;; Done) printf '%s' "$BOARD_OPT_STATUS_DONE" ;; *) return 1 ;; esac; }
prio_opt() { case "$1" in
  P0) printf '%s' "$BOARD_OPT_PRIORITY_P0" ;; P1) printf '%s' "$BOARD_OPT_PRIORITY_P1" ;; P2) printf '%s' "$BOARD_OPT_PRIORITY_P2" ;;
  P3) printf '%s' "$BOARD_OPT_PRIORITY_P3" ;; Unspecified) printf '%s' "$BOARD_OPT_PRIORITY_UNSPECIFIED" ;; *) return 1 ;; esac; }

# ---- 4. current board items (GraphQL, fully paginated) -> normalized array ------------------------
GQL='query($id:ID!,$c:String){node(id:$id){... on ProjectV2{items(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{id fieldValues(first:30){nodes{__typename ... on ProjectV2ItemFieldTextValue{text field{... on ProjectV2FieldCommon{name}}} ... on ProjectV2ItemFieldSingleSelectValue{name field{... on ProjectV2FieldCommon{name}}}}}}}}}}'
read_board_items() {
  if [ -n "${BOARD_ITEMS_FILE:-}" ]; then cat "$BOARD_ITEMS_FILE"; return; fi   # test seam: normalized items array
  local cursor="" out="[]" resp page; local -a args
  while :; do
    args=(api graphql -f query="$GQL" -F id="$BOARD_PROJECT_NODE_ID")
    [ -n "$cursor" ] && args+=(-F c="$cursor")
    resp="$(gh_ "${args[@]}" 2>/dev/null)" || die "graphql item read failed"
    page="$(printf '%s' "$resp" | jq -c '[.data.node.items.nodes[] | {itemId:.id, f:([.fieldValues.nodes[] | select(.field.name!=null) | {(.field.name):(.text // .name)}] | add // {})} | {itemId, beadId:(.f["Bead ID"]//""), title:(.f["Title"]//""), status:(.f["Status"]//""), priority:(.f["Priority"]//""), assignee:(.f["Bead Assignee"]//""), blockedBy:(.f["Blocked-by"]//"")}]')"
    out="$(jq -c -n --argjson a "$out" --argjson b "$page" '$a + $b')"
    [ "$(printf '%s' "$resp" | jq -r '.data.node.items.pageInfo.hasNextPage')" = true ] || break
    cursor="$(printf '%s' "$resp" | jq -r '.data.node.items.pageInfo.endCursor')"
  done
  printf '%s' "$out"
}
items="$(read_board_items)"
dup="$(printf '%s' "$items" | jq -r '[.[] | select(.beadId!="") | .beadId] | group_by(.)[] | select(length>1)[0]')"
[ -z "$dup" ] || die "board has duplicate Bead ID '$dup' on >1 item — ambiguous join target; refusing (archive the dup by hand)"
item_for()  { printf '%s' "$items" | jq -r --arg b "$1" 'first(.[] | select(.beadId==$b) | .itemId) // empty'; }
cur_field() { printf '%s' "$items" | jq -r --arg b "$1" --arg k "$2" 'first(.[] | select(.beadId==$b) | .[$k]) // ""'; }

# ---- write helpers (item-edit always needs the project NODE id) -----------------------------------
NODE="$BOARD_PROJECT_NODE_ID"
edit_opt()  { gh_ project item-edit --id "$1" --project-id "$NODE" --field-id "$2" --single-select-option-id "$3" >/dev/null || die "item-edit (option) failed for $1"; }
edit_text() { if [ -z "$3" ]; then gh_ project item-edit --id "$1" --project-id "$NODE" --field-id "$2" --clear >/dev/null || die "item-edit (clear) failed for $1";
              else gh_ project item-edit --id "$1" --project-id "$NODE" --field-id "$2" --text "$3" >/dev/null || die "item-edit (text) failed for $1"; fi; }

creates=0; updates=0; archives=0; unchanged=0; seen=""
plan() { printf '  %s\n' "$1"; }
echo "board-sync [$MODE] — ${BOARD_PROJECT_NUMBER}@${BOARD_OWNER}  ($(printf '%s' "$contract" | jq 'length') beads, digest ${digest:0:12})"

# ---- 5. upsert (Beads-wins, idempotent): create-or-update each bead by Bead ID -------------------
while IFS= read -r b; do
  [ -n "$b" ] || continue
  id="$(jq -r '.id' <<<"$b")"; title="$(jq -r '.title' <<<"$b")"
  lane="$(jq -r '.lane' <<<"$b")"; prio="$(jq -r '.prio' <<<"$b")"
  asg="$(jq -r '.assignee' <<<"$b")"; blk="$(jq -r '.blocked_by' <<<"$b")"
  sopt="$(status_opt "$lane")" || die "no option id for lane '$lane' — board.config stale? re-run board-bootstrap.sh"
  popt="$(prio_opt "$prio")" || die "no option id for priority '$prio'"
  seen="$seen $id"
  itemId="$(item_for "$id")"
  if [ -z "$itemId" ]; then
    plan "CREATE  $id  [$lane/$prio]  \"$title\""
    if [ "$MODE" = sync ]; then
      itemId="$(gh_ project item-create "$BOARD_PROJECT_NUMBER" --owner "$BOARD_OWNER" --title "$title" --format json | jq -r '.id')"
      [ -n "$itemId" ] && [ "$itemId" != null ] || die "item-create failed for $id"
      edit_text "$itemId" "$BOARD_FIELD_BEAD_ID" "$id"        # JOIN KEY FIRST (crash-safe resume)
      edit_opt  "$itemId" "$BOARD_FIELD_STATUS" "$sopt"
      edit_opt  "$itemId" "$BOARD_FIELD_PRIORITY" "$popt"
      edit_text "$itemId" "$BOARD_FIELD_BEAD_ASSIGNEE" "$asg"
      edit_text "$itemId" "$BOARD_FIELD_BLOCKED_BY" "$blk"
    fi
    creates=$((creates + 1))
  else
    changes=()
    [ "$(cur_field "$id" title)" = "$title" ] || changes+=(title)
    [ "$(cur_field "$id" status)" = "$lane" ] || changes+=(status)
    [ "$(cur_field "$id" priority)" = "$prio" ] || changes+=(priority)
    [ "$(cur_field "$id" assignee)" = "$asg" ] || changes+=(assignee)
    [ "$(cur_field "$id" blockedBy)" = "$blk" ] || changes+=(blockedBy)
    if [ "${#changes[@]}" -eq 0 ]; then unchanged=$((unchanged + 1)); else
      plan "UPDATE  $id  {${changes[*]}}"
      if [ "$MODE" = sync ]; then
        for c in "${changes[@]}"; do case "$c" in
          title) gh_ project item-edit --id "$itemId" --project-id "$NODE" --title "$title" >/dev/null || die "item-edit (title) failed for $id" ;;
          status) edit_opt "$itemId" "$BOARD_FIELD_STATUS" "$sopt" ;;
          priority) edit_opt "$itemId" "$BOARD_FIELD_PRIORITY" "$popt" ;;
          assignee) edit_text "$itemId" "$BOARD_FIELD_BEAD_ASSIGNEE" "$asg" ;;
          blockedBy) edit_text "$itemId" "$BOARD_FIELD_BLOCKED_BY" "$blk" ;;
        esac; done
      fi
      updates=$((updates + 1))
    fi
  fi
done < <(printf '%s' "$desired" | jq -c '.[]')

# ---- 6. archive-on-absence (A): board item whose Bead ID is not in the contract ------------------
while IFS= read -r row; do
  [ -n "$row" ] || continue
  bid="$(jq -r '.beadId' <<<"$row")"; iid="$(jq -r '.itemId' <<<"$row")"
  if [ -z "$bid" ]; then plan "SKIP    <empty Bead ID> item=$iid (not tool-managed; left untouched)"; continue; fi
  case " $seen " in *" $bid "*) ;; *)
    plan "ARCHIVE $bid  (absent from contract → deleted or closed-beyond-window)"
    if [ "$MODE" = sync ]; then gh_ project item-archive "$BOARD_PROJECT_NUMBER" --owner "$BOARD_OWNER" --id "$iid" >/dev/null || die "item-archive failed for $bid"; fi
    archives=$((archives + 1)) ;;
  esac
done < <(printf '%s' "$items" | jq -c '.[]')

actions=$((creates + updates + archives))
echo "  → create:$creates update:$updates archive:$archives unchanged:$unchanged"

# ---- 7. per-mode finalize ------------------------------------------------------------------------
case "$MODE" in
  dry-run)
    echo "board-sync: DRY-RUN — no writes made."; exit 0 ;;
  check)
    prev="$(jq -r '.digest // ""' "$STATE" 2>/dev/null || true)"
    if [ "$actions" -eq 0 ] && [ "$digest" = "$prev" ]; then
      echo "board-sync: FRESH — board is a faithful index (digest ${digest:0:12})."; exit 0
    fi
    echo "board-sync: DRIFT — board != Beads. contract digest ${digest:0:12}, last-synced ${prev:0:12}; ${actions} reconciling action(s) above. Run 'board-sync.sh sync' to rebuild the index."; exit 1 ;;
  sync)
    prev="$(jq -r '.digest // ""' "$STATE" 2>/dev/null || true)"
    if [ "$actions" -eq 0 ] && [ "$digest" = "$prev" ]; then
      echo "board-sync: SYNCED — already a faithful index (digest ${digest:0:12}); no writes."; exit 0
    fi
    # stamp the freshness digest on the index itself (README) + harness state (git-ignored)
    readme="$(printf 'Read-only projection of Beads (the source of truth). Do NOT hand-edit — values are\noverwritten by board-sync. One bead → one item, joined by Bead ID.\n\nbeads-index-digest: %s\nbeads-count: %s\nsynced-at: %s\n' "$digest" "$(printf '%s' "$contract" | jq 'length')" "$(date -u +%FT%TZ)")"
    gh_ project edit "$BOARD_PROJECT_NUMBER" --owner "$BOARD_OWNER" --readme "$readme" >/dev/null 2>&1 || echo "  warn: README digest stamp failed (continuing)" >&2
    mkdir -p "$(dirname "$STATE")"
    jq -n --arg d "$digest" --argjson c "$(printf '%s' "$contract" | jq 'length')" --arg t "$(date -u +%FT%TZ)" '{digest:$d,count:$c,synced_at:$t}' >"$STATE"
    echo "board-sync: SYNCED — digest ${digest:0:12} stamped."; exit 0 ;;
esac
