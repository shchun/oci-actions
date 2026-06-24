# oci-actions

Creates an Oracle Cloud **Always Free** ARM instance (`VM.Standard.A1.Flex`)
via a GitHub Actions workflow. Free ARM capacity is scarce, so the workflow is
designed to run on a loop and retry until capacity is available, then report to
Slack.

This repo is a self-contained unit — workflow, trigger script, deploy agent,
and docs all version together:

- Workflow (the receiving end): [.github/workflows/create-vm.yml](.github/workflows/create-vm.yml)
- Trigger script (the sending end, source of truth): [trigger.sh](trigger.sh)
- Deploy agent (installs the trigger on the VM): [.claude/agents/oci-trigger-deployer.md](.claude/agents/oci-trigger-deployer.md)
- Secrets template: [.env.example](.env.example)

## How it works

The workflow ([create-vm.yml](.github/workflows/create-vm.yml)) is triggered two ways:

1. `workflow_dispatch` — manual or API-driven runs (this is what the VM cron uses).
2. `schedule` — a built-in `*/10 * * * *` cron as a fallback.

Each run:

1. Configures the OCI CLI from repo secrets.
2. **Guards against duplicates** — skips launch if a live instance with the same
   `display_name` already exists, so it's safe to run on a loop.
3. Attempts `oci compute instance launch`. "Out of host capacity", throttling,
   and transient network errors are **retried** (configurable); other errors fail.
4. On success, fetches the public IP and notifies Slack. "No capacity" outcomes
   stay silent on Slack for automated runs (`quiet=true` / scheduled).

### Free-tier shape defaults

| Input | Default | Free-tier max |
| --- | --- | --- |
| `ocpus` | `2` | `2` |
| `memory_in_gbs` | `12` | `12` |
| `boot_volume_size_gb` | `200` | `200` |

> Oracle [halved](https://linuxiac.com/oracle-quietly-cuts-free-tier-ampere-a1-resources-in-half/)
> the Always Free Ampere A1 allocation from 4 OCPU / 24 GB to **2 OCPU / 12 GB**.
> The defaults above reflect the current limit.

## Setup

### 1. Repository secrets

Add every secret listed at the top of
[create-vm.yml](.github/workflows/create-vm.yml) (values come from your `.env`,
see [.env.example](.env.example)):

```
OCI_USER_OCID, OCI_TENANCY_OCID, OCI_REGION, OCI_FINGERPRINT,
OCI_PRIVATE_KEY (full PEM text), OCI_SUBNET_OCID, OCI_IMAGE_OCID,
OCI_SSH_PUBLIC_KEY (full public key text), OCI_COMPARTMENT_OCID,
OCI_AD, OCI_SHAPE, SLACK_WEBHOOK_URL
```

### 2. External cron trigger (the AWS VM)

**Why not rely on GitHub's own `schedule`?** GitHub's scheduled triggers are
unreliable under load — the `*/10 * * * *` cron in the workflow often fires
every 2–3 hours instead of every 10 minutes. Since free ARM capacity appears in
short windows, missing those windows means missing the VM. So an external host
(an AWS EC2 VM) dispatches the workflow on a **real** 10-minute cron via the
GitHub REST API. The in-repo `schedule` remains only as a fallback.

The VM runs this from `crontab -l`:

```cron
*/10 * * * * /home/ubuntu/oci-vm-trigger/trigger.sh
```

The script deployed to `~/oci-vm-trigger/trigger.sh` is the git-tracked
[trigger.sh](trigger.sh) in this repo (source of truth — edit there, commit,
redeploy with the `oci-trigger-deployer` agent):

```bash
#!/usr/bin/env bash
# Triggers the OCI VM creation GitHub Action via workflow_dispatch.
# Run every 10 min by cron (GitHub's own schedule is unreliable, often
# firing every 2-3h instead of 10m).
#
# inputs:
#   max_attempts=5       -> retry up to 5x within a single run (each capacity
#                           error takes ~1.6 min; with a 30s delay this keeps a
#                           run at roughly 10 min so runs don't pile up).
#   retry_delay_seconds=30
#   quiet=true           -> stay silent on Slack for "no capacity" outcomes.
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
```

**Token**: a GitHub PAT (fine-grained, with **Actions: read/write** on
`shchun/oci-actions`) stored at `~/.config/oci-trigger/token`. Lock it down:

```bash
mkdir -p ~/.config/oci-trigger
printf '%s' 'github_pat_xxx' > ~/.config/oci-trigger/token
chmod 600 ~/.config/oci-trigger/token
```

**Dispatch inputs** sent each run:

| Input | Value | Effect |
| --- | --- | --- |
| `max_attempts` | `5` | Retry up to 5× capacity errors within one run (~10 min total). |
| `retry_delay_seconds` | `30` | Wait between retries. |
| `quiet` | `true` | No Slack noise on "no capacity"; success/failure still posts. |

Shape inputs are **not** sent, so each run uses the workflow defaults
(2 OCPU / 12 GB). To request a different size, add e.g.
`"ocpus":"1","memory_in_gbs":"6"` to the `inputs` JSON.

**Verify it's working** on the VM:

```bash
tail -f ~/oci-vm-trigger/trigger.log    # expect: ...dispatch -> HTTP 204 every 10 min
```

`HTTP 204` = accepted. Anything else (401/403/404) means a token or
repo/workflow-name problem.

### 3. Deploying the trigger to the VM

Use the **`oci-trigger-deployer`** agent
([.claude/agents/oci-trigger-deployer.md](.claude/agents/oci-trigger-deployer.md)).
Given the VM's public IP and SSH key path, it `scp`s [trigger.sh](trigger.sh)
to `~/oci-vm-trigger/trigger.sh`, ensures the token file exists, installs the
`*/10` crontab entry (without clobbering other cron jobs), and verifies the
first dispatch returns `HTTP 204`. The VM's public IP changes on reboot, so it
is passed at invocation time rather than hardcoded.
