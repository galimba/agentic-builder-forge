#!/usr/bin/env bash
# Target A2 RED-first: bd cold-start self-heal in forge_beads_preflight.
#
# A freshly `bd init`'d DB whose ONE-TIME `bd config set status.custom in_review:wip` (harness/beads.config)
# was skipped currently fails preflight (the custom status read at beads-lib.sh:108 misses -> rc 1 ->
# run-task.sh start/finish fail-close at :102/:328, forcing an operator re-run). The fix materializes the
# status ONCE then RE-READS, fail-closed on the re-read (the verdict gates on the read, never the write).
#
#   GREEN (deployed lib — the A2 fix has landed): preflight returns 0 AND the status is
#         now declared. (Pre-splice RED: cold-start preflight returned 1, no self-heal.)
#   FAIL-CLOSED canary:     a bd whose `config set` cannot materialize the status MUST still rc 1.
#
# Seam: FORGE_BEADS_LIB overrides the lib under test (candidate overlays). The subject is the
# REAL bd round-trip -> SKIP 75 if bd is absent (never pass vacuously). No network.
#   bash tests/boundary/fold20-bd-coldstart.sh   # GREEN vs the deployed lib (standing regression lock; package.json "test:fold20-coldstart")
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
_gcd="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; LIVE_ROOT="$(dirname "$_gcd")"; unset _gcd
DEPLOYED="$LIVE_ROOT/harness/beads-lib.sh"
export FORGE_DEPLOYED_BEADS_LIB="$DEPLOYED"          # the candidate overlay sources this for unchanged fns
# shellcheck disable=SC1090
. "${FORGE_BEADS_LIB:-$DEPLOYED}"                    # RED: deployed; GREEN: FORGE_BEADS_LIB=<candidate overlay>
P=0; F=0; ok(){ P=$((P+1)); printf '  PASS [%s]\n' "$1"; }; bad(){ F=$((F+1)); printf '  FAIL [%s] %s\n' "$1" "${2:-}"; }
FLOOR_PRE="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
command -v bd >/dev/null 2>&1 || { echo "  SKIP (bd absent)"; echo "==== fold20-bd-coldstart: SKIP ===="; exit 75; }

# the version pin must not confound the status arm (test the STATUS path, not version drift)
export BD_ALLOW_VERSION_DRIFT=1
# the lib's status constants, so the test is independent of whether beads.config was loaded
export BD_REVIEW_STATUS="in_review"
export BD_REVIEW_STATUS_DECL="in_review:wip"

TMP="$(mktemp -d)"; cleanup(){ rm -rf "$TMP" 2>/dev/null; }; trap cleanup EXIT

# ── arm 1: genuine cold start — `bd init` WITHOUT `bd config set status.custom` ──────────────────
export ROOT="$TMP/cold"; mkdir -p "$ROOT"
( cd "$ROOT" && git init -q && git config user.email t@t && git config user.name t && bd init --non-interactive >/dev/null 2>&1 )
# precondition: in_review is genuinely UNDECLARED on the cold DB
if bd -C "$ROOT" statuses 2>/dev/null | grep -qw in_review; then
  bad "precondition: in_review should be UNDECLARED on the cold DB" "it was already declared"
else
  ok "precondition: cold DB has in_review UNDECLARED"
fi
forge_beads_preflight 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "cold-start preflight returns 0 (self-healed within the call)"
  if bd -C "$ROOT" statuses 2>/dev/null | grep -qw in_review; then
    ok "in_review is now DECLARED (materialized by the self-heal)"
  else
    bad "preflight returned 0 but the status is still undeclared" "materialize did not persist"
  fi
else
  bad "cold-start preflight returned $rc — it did not self-heal (RED on the deployed lib)" "rc=$rc"
fi

# ── arm 2: idempotence — a SECOND preflight on the now-warm DB still returns 0 ────────────────────
forge_beads_preflight 2>/dev/null; rc2=$?
[ "$rc2" -eq 0 ] && ok "idempotent: second preflight on the warm DB returns 0 (no warm-path change)" \
  || bad "second preflight returned $rc2 (should be 0)" ""

# ── arm 3: FAIL-CLOSED canary — a bd that CANNOT materialize the status must still rc 1 ───────────
# fake bd: version OK; `statuses` NEVER lists in_review; `config set` exits non-zero (cannot materialize).
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/bd" <<'FAKE'
#!/usr/bin/env bash
case "$1" in -C) shift 2 ;; esac   # drop the leading `-C <dir>` forge_bd always passes
case "$1" in
  version)  echo "bd version 1.0.4 (fake)" ;;
  statuses) printf 'open\nin_progress\nclosed\n' ;;   # in_review is NEVER declared here
  config)   exit 3 ;;                                  # `config set status.custom ...` FAILS
  *)        exit 0 ;;
esac
FAKE
chmod +x "$TMP/fakebin/bd"
if ( export BD_BIN="$TMP/fakebin/bd"; forge_beads_preflight 2>/dev/null ); then
  bad "FAIL-CLOSED canary: preflight returned 0 when materialization is impossible — it FELL OPEN" "must be non-zero"
else
  ok "FAIL-CLOSED: a bd that cannot materialize the status still returns non-zero (gates on the re-read, not the write)"
fi

FLOOR_POST="$(git -C "$LIVE_ROOT" hash-object .claude/hooks/lib.sh)"
[ "$FLOOR_PRE" = "$FLOOR_POST" ] && ok "live floor intact (.claude/hooks/lib.sh unchanged)" || bad "LIVE FLOOR CHANGED" ""
echo "==== fold20-bd-coldstart: $P passed, $F failed ===="
[ "$F" -eq 0 ]
