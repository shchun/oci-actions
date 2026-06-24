#!/usr/bin/env bash
# Triggers the OCI VM creation GitHub Action via workflow_dispatch.
# Installed on the AWS VM and run every 10 min by cron (GitHub's own
# schedule is unreliable, often firing every 2-3h instead of 10m).
#
# Deploy with the oci-trigger-deployer agent, which scp's THIS file to
# ~/oci-vm-trigger/trigger.sh on the VM. This repo copy is the source of
# truth — edit here, commit, then redeploy.
#
# inputs:
#   max_attempts=5      -> retry up to 5x within a single run (each capacity
#                          error takes ~1.6 min; with a 30s delay this keeps a
#                          run at roughly 10 min so runs don't pile up).
#   retry_delay_seconds=30
#   quiet=true          -> stay silent on Slack for "no capacity" outcomes.
set -uo pipefail

REPO="shchun/oci-actions"
WF="create-vm.yml"
TOKEN_FILE="$HOME/.config/oci-trigger/token"
LOG="$HOME/oci-vm-trigger/trigger.log"

token=$(tr -d '\r\n' < "$TOKEN_FILE")
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${REPO}/actions/workflows/${WF}/dispatches" \
  -d '{"ref":"main","inputs":{"max_attempts":"5","retry_delay_seconds":"30","quiet":"true"}}')

echo "${ts} dispatch -> HTTP ${code}" >> "$LOG"

# Keep the log from growing forever (last 1000 lines).
tail -n 1000 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
