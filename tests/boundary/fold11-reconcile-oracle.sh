#!/usr/bin/env bash
# RETIRED — FOLD #11 (reconcile external_ref repo-match) was SUPERSEDED by FOLD #13's trust-model
# redesign: the close decision now reads the HARNESS-CAPTURED PR identity (.harness/pr/<bead>.json), and
# external_ref is out of the decision entirely. forge_reconcile_repo_of was removed. This file is not
# registered (package.json uses test:fold13-reconcile → tests/boundary/fold13-reconcile-trustmodel.sh).
echo "fold11-reconcile-oracle: RETIRED (superseded by fold13 trust-model). See tests/boundary/fold13-reconcile-trustmodel.sh"
exit 0
