#!/bin/bash
# EARTHSHINE-1 — one-command GCP provision. Runs on your laptop.
# Creates: T4 VM with startup.sh attached, email notification channel,
# CPU-drop alert policy. Idempotent — safe to re-run.
#
# Usage:
#   STREAM_KEY="xxxx-xxxx-xxxx-xxxx-xxxx" \
#   AMBIENT_GCS_URL="gs://your-bucket/ambient.mp3" \
#   ./provision.sh
#
# Or run with no env vars and it'll prompt you.
#
# Override defaults:
#   PROJECT, ZONE, VM_NAME, MACHINE_TYPE, EMAIL

set -euo pipefail

# --- defaults ---
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-earthshine-stream}"
MACHINE_TYPE="${MACHINE_TYPE:-n1-standard-4}"
EMAIL="${EMAIL:-dcastro@thirdteam.org}"
STREAM_KEY="${STREAM_KEY:-}"
AMBIENT_GCS_URL="${AMBIENT_GCS_URL:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STARTUP_SCRIPT="$SCRIPT_DIR/startup.sh"

# --- helpers ---
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
say()  { echo "${BOLD}==>${RESET} $*"; }
ok()   { echo "${GREEN}  ✓${RESET} $*"; }
warn() { echo "${YELLOW}  !${RESET} $*"; }
die()  { echo "${RED}  ✗${RESET} $*" >&2; exit 1; }

# --- preflight ---
say "Preflight"

command -v gcloud >/dev/null 2>&1 || die "gcloud not installed. Install: brew install --cask google-cloud-sdk"
command -v gsutil >/dev/null 2>&1 || die "gsutil missing (should come with gcloud)"
[ -f "$STARTUP_SCRIPT" ] || die "startup.sh not found at $STARTUP_SCRIPT"

ACTIVE_ACCT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
[ -n "$ACTIVE_ACCT" ] || die "Not authenticated. Run: gcloud auth login"
ok "auth: $ACTIVE_ACCT"

[ -n "$PROJECT" ] || die "No project set. Run: gcloud config set project <PROJECT_ID>"
gcloud projects describe "$PROJECT" >/dev/null 2>&1 || die "Cannot access project $PROJECT"
ok "project: $PROJECT"

for api in compute monitoring logging; do
  STATE=$(gcloud services list --enabled --project "$PROJECT" \
    --filter="config.name=${api}.googleapis.com" --format="value(state)" 2>/dev/null | head -1)
  [ "$STATE" = "ENABLED" ] || die "API ${api}.googleapis.com not enabled. Run: gcloud services enable ${api}.googleapis.com"
done
ok "APIs: compute, monitoring, logging"

# --- inputs ---
if [ -z "$STREAM_KEY" ]; then
  echo
  read -rsp "  Paste YouTube Stream Key (hidden): " STREAM_KEY
  echo
fi
[ -n "$STREAM_KEY" ] || die "STREAM_KEY required"

if [ -z "$AMBIENT_GCS_URL" ]; then
  read -rp "  GCS path to ambient.mp3 (e.g. gs://earthshine-ops/ambient.mp3): " AMBIENT_GCS_URL
fi
[ -n "$AMBIENT_GCS_URL" ] || die "AMBIENT_GCS_URL required"

# Validate the audio actually exists and is readable.
gsutil stat "$AMBIENT_GCS_URL" >/dev/null 2>&1 \
  || die "Audio not found at $AMBIENT_GCS_URL. Upload first: gsutil cp ambient.mp3 $AMBIENT_GCS_URL"
ok "audio: $AMBIENT_GCS_URL"

# --- confirm ---
echo
echo "${BOLD}About to provision:${RESET}"
echo "  Project:      $PROJECT"
echo "  Zone:         $ZONE"
echo "  VM:           $VM_NAME ($MACHINE_TYPE + 1× NVIDIA T4)"
echo "  Audio:        $AMBIENT_GCS_URL"
echo "  Alert email:  $EMAIL"
echo "  Cost:         ~\$257/mo on-demand (T4 + n1-standard-4 + 50GB pd-balanced)"
echo
read -rp "  Proceed? [y/N] " CONFIRM
case "$CONFIRM" in y|Y|yes|YES) ;; *) die "Aborted" ;; esac

# --- handle existing VM ---
if gcloud compute instances describe "$VM_NAME" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
  warn "VM $VM_NAME already exists in $ZONE"
  read -rp "  Delete and recreate? [y/N] " RECREATE
  case "$RECREATE" in
    y|Y|yes|YES)
      say "Deleting existing VM"
      gcloud compute instances delete "$VM_NAME" --zone "$ZONE" --project "$PROJECT" --quiet
      ;;
    *) die "Aborted (VM exists, not recreating)" ;;
  esac
fi

# --- create VM ---
say "Creating VM"
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --accelerator="type=nvidia-tesla-t4,count=1" \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-balanced \
  --maintenance-policy=TERMINATE \
  --restart-on-failure \
  --metadata="stream-key=${STREAM_KEY},ambient-url=${AMBIENT_GCS_URL}" \
  --metadata-from-file="startup-script=${STARTUP_SCRIPT}" \
  --scopes=cloud-platform \
  --tags=earthshine
ok "VM created"

INSTANCE_ID=$(gcloud compute instances describe "$VM_NAME" --zone "$ZONE" --project "$PROJECT" --format="value(id)")
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" --zone "$ZONE" --project "$PROJECT" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
ok "instance id: $INSTANCE_ID  ip: $EXTERNAL_IP"

# --- email notification channel (idempotent) ---
say "Email alert channel"
CHANNEL_ID=$(gcloud alpha monitoring channels list --project "$PROJECT" \
  --filter="labels.email_address=$EMAIL AND type=email" \
  --format="value(name)" 2>/dev/null | head -1 || true)

if [ -z "$CHANNEL_ID" ]; then
  CHANNEL_ID=$(gcloud alpha monitoring channels create --project "$PROJECT" \
    --display-name="EARTHSHINE alerts" \
    --type=email \
    --channel-labels="email_address=${EMAIL}" \
    --format="value(name)")
  ok "created: $CHANNEL_ID"
else
  ok "reusing: $CHANNEL_ID"
fi

# --- alert policy: CPU drop = stream broken (idempotent) ---
# ffmpeg + chrome run at 20-40% CPU consistently. If average CPU is below 5%
# for 5+ minutes the stream is dead (process crashed, VM hung, or VM stopped
# and no metric arrives at all — both fire this alert).
say "Alert policy"

POLICY_NAME="EARTHSHINE stream broken — CPU dropout"
EXISTING_POLICY=$(gcloud alpha monitoring policies list --project "$PROJECT" \
  --filter="displayName='$POLICY_NAME'" --format="value(name)" 2>/dev/null | head -1 || true)

POLICY_FILE=$(mktemp)
cat > "$POLICY_FILE" <<JSON
{
  "displayName": "$POLICY_NAME",
  "combiner": "OR",
  "conditions": [{
    "displayName": "CPU below 5% for 5 minutes on $VM_NAME",
    "conditionThreshold": {
      "filter": "resource.type=\"gce_instance\" AND metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.labels.instance_id=\"$INSTANCE_ID\"",
      "comparison": "COMPARISON_LT",
      "thresholdValue": 0.05,
      "duration": "300s",
      "aggregations": [{
        "alignmentPeriod": "60s",
        "perSeriesAligner": "ALIGN_MEAN"
      }],
      "trigger": { "count": 1 }
    }
  }],
  "notificationChannels": ["$CHANNEL_ID"],
  "alertStrategy": { "autoClose": "3600s" }
}
JSON

if [ -n "$EXISTING_POLICY" ]; then
  warn "policy exists, not modifying ($EXISTING_POLICY)"
else
  gcloud alpha monitoring policies create --project "$PROJECT" --policy-from-file="$POLICY_FILE" >/dev/null
  ok "policy created"
fi
rm -f "$POLICY_FILE"

# --- done ---
cat <<DONE

${GREEN}${BOLD}Done.${RESET} First-boot install runs now (~10 min: nvidia driver, reboot, chromium warmup, ffmpeg).

${BOLD}Watch first-boot progress:${RESET}
  gcloud compute ssh $VM_NAME --zone $ZONE --project $PROJECT \\
    -- "sudo tail -f /var/log/earthshine-startup.log"

${BOLD}Once running:${RESET}
  # Stream service status
  gcloud compute ssh $VM_NAME --zone $ZONE -- "sudo systemctl status earthshine-stream"

  # Live tail of chromium + ffmpeg
  gcloud compute ssh $VM_NAME --zone $ZONE -- "sudo journalctl -u earthshine-stream -f"

  # Force chromium reload (manual deploy refresh)
  gcloud compute ssh $VM_NAME --zone $ZONE -- "sudo systemctl restart earthshine-stream"

  # Open shell on the VM
  gcloud compute ssh $VM_NAME --zone $ZONE

${BOLD}Stop streaming (stops billing for compute):${RESET}
  gcloud compute instances stop $VM_NAME --zone $ZONE

${BOLD}Resume:${RESET}
  gcloud compute instances start $VM_NAME --zone $ZONE
  # services auto-start on boot, no extra action needed

${BOLD}Nuclear option — delete everything:${RESET}
  gcloud compute instances delete $VM_NAME --zone $ZONE --quiet

${BOLD}Watch your stream:${RESET}
  https://studio.youtube.com → Live  (appears within 5–10 min of provision)

DONE
