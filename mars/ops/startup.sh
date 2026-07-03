#!/bin/bash
# MARSSHINE-1 VM startup. Runs on first boot (Compute Engine metadata
# startup-script). Idempotent — re-runs on every boot but skips heavy steps
# once /opt/marsshine/.provisioned exists.
#
# What this builds on the VM:
#   /etc/systemd/system/marsshine-x.service        — headless Xorg on :0
#   /etc/systemd/system/marsshine-stream.service   — chromium + ffmpeg → YouTube
#   /etc/systemd/system/marsshine-reload.timer     — nightly reload at 04:00 UTC
#   /etc/systemd/system/marsshine-redeploy.timer   — build-tag poller, every 60s
#
# Metadata it reads:
#   stream-key       — YouTube Live stream key
#   ambient-url      — gs:// path to a long ambient audio MP3

set -euo pipefail
exec > >(tee -a /var/log/marsshine-startup.log) 2>&1
echo "=== marsshine startup $(date -u) ==="

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
mdget() { curl -fsH "Metadata-Flavor: Google" "$META/$1"; }

STREAM_KEY="$(mdget stream-key)"
AMBIENT_URL="$(mdget ambient-url)"
MARSSHINE_URL="https://marsshine.transcendiant.net/?pov=1"

if [ -f /opt/marsshine/.provisioned ]; then
  echo "already provisioned, ensuring services are up"
  systemctl daemon-reload
  systemctl restart marsshine-x.service marsshine-stream.service
  exit 0
fi

mkdir -p /opt/marsshine /var/lib/marsshine

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  curl gnupg ca-certificates jq python3 python3-pip \
  xserver-xorg-core xserver-xorg-video-dummy xinit x11-xserver-utils \
  xdotool x11-utils \
  ffmpeg \
  chromium-browser \
  google-cloud-cli

# NVIDIA driver for the T4 via GCP's official installer (handles kernel headers,
# DKMS, reboots-required flag detection). Slow step, ~5 min.
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "installing NVIDIA driver"
  curl -fsSL https://raw.githubusercontent.com/GoogleCloudPlatform/compute-gpu-installation/main/linux/install_gpu_driver.py -o /tmp/install_gpu_driver.py
  python3 /tmp/install_gpu_driver.py || {
    echo "GPU driver install reported failure; will retry next boot"
    exit 1
  }
fi

# Pull ambient audio loop from GCS.
gsutil cp "$AMBIENT_URL" /opt/marsshine/ambient.mp3

# Xorg config: T4 headless. nvidia-xconfig writes /etc/X11/xorg.conf with
# AllowEmptyInitialConfiguration so X starts with no monitor attached.
nvidia-xconfig --enable-all-gpus --use-display-device=none \
  --connected-monitor=DFP --virtual=1920x1080 || true

# === streamer script ===
cat >/usr/local/bin/marsshine-stream.sh <<STREAMSH
#!/bin/bash
set -euo pipefail

export DISPLAY=:0
STREAM_KEY="\$(curl -fsH "Metadata-Flavor: Google" $META/stream-key)"

# Wait for X to be ready (race with marsshine-x.service start).
for i in \$(seq 1 30); do
  xdpyinfo >/dev/null 2>&1 && break
  sleep 1
done

# Chromium. Kiosk mode, no sandbox (we're root in a VM), GPU enabled.
# --user-data-dir is recreated each launch to avoid persistent state corruption.
rm -rf /tmp/chrome-marsshine
chromium-browser \\
  --user-data-dir=/tmp/chrome-marsshine \\
  --no-sandbox --no-first-run --noerrdialogs \\
  --disable-infobars --disable-translate --disable-features=TranslateUI \\
  --disable-session-crashed-bubble \\
  --autoplay-policy=no-user-gesture-required \\
  --kiosk \\
  --window-size=1920,1080 --window-position=0,0 \\
  --use-gl=egl --enable-features=Vulkan \\
  "$MARSSHINE_URL" &
CHROMIUM_PID=\$!

# Give chromium time to load WebGL, textures, sim warmup.
sleep 25

# When ffmpeg exits, kill chromium so systemd can restart the whole service
# clean rather than leaving an orphan chrome.
trap "kill -TERM \$CHROMIUM_PID 2>/dev/null || true; sleep 2; kill -KILL \$CHROMIUM_PID 2>/dev/null || true" EXIT

exec ffmpeg -hide_banner -loglevel warning \\
  -f x11grab -video_size 1920x1080 -framerate 30 -i :0.0 \\
  -stream_loop -1 -i /opt/marsshine/ambient.mp3 \\
  -c:v h264_nvenc -preset p4 -profile:v high -rc:v cbr -b:v 6000k -maxrate 6000k -bufsize 12000k -g 60 \\
  -c:a aac -b:a 128k -ar 44100 -ac 2 \\
  -map 0:v:0 -map 1:a:0 \\
  -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \\
  -f flv "rtmp://a.rtmp.youtube.com/live2/\$STREAM_KEY"
STREAMSH
chmod +x /usr/local/bin/marsshine-stream.sh

# === build-tag poller (replaces Cloud Scheduler) ===
cat >/usr/local/bin/marsshine-redeploy-check.sh <<'POLL'
#!/bin/bash
set -euo pipefail
URL="https://marsshine.transcendiant.net/"
STATE=/var/lib/marsshine/build-tag
CURRENT=$(curl -fsSL --max-time 10 "$URL" 2>/dev/null | grep -oE "build r[0-9.]+" | head -1 || true)
[ -z "$CURRENT" ] && exit 0
PREVIOUS=$(cat "$STATE" 2>/dev/null || echo "")
if [ "$CURRENT" != "$PREVIOUS" ]; then
  echo "$CURRENT" > "$STATE"
  if [ -n "$PREVIOUS" ]; then
    # Reload chromium so the new build appears on stream. <30s blip.
    DISPLAY=:0 xdotool search --name "MARSSHINE" 2>/dev/null \
      | head -1 \
      | xargs -r -I{} xdotool key --window {} F5
    logger -t marsshine "build $PREVIOUS → $CURRENT, reloaded chromium"
  else
    logger -t marsshine "build $CURRENT (first observation, no reload)"
  fi
fi
POLL
chmod +x /usr/local/bin/marsshine-redeploy-check.sh

# === nightly memory-leak reload ===
cat >/usr/local/bin/marsshine-reload.sh <<'RELOAD'
#!/bin/bash
DISPLAY=:0 xdotool search --name "MARSSHINE" 2>/dev/null \
  | head -1 \
  | xargs -r -I{} xdotool key --window {} F5
logger -t marsshine "nightly reload triggered"
RELOAD
chmod +x /usr/local/bin/marsshine-reload.sh

# === systemd units ===
cat >/etc/systemd/system/marsshine-x.service <<'EOF'
[Unit]
Description=Xorg :0 (headless, NVIDIA T4)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/Xorg :0 -nolisten tcp -noreset +extension GLX +extension RANDR +extension RENDER
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/marsshine-stream.service <<'EOF'
[Unit]
Description=MARSSHINE chromium + ffmpeg → YouTube RTMP
After=marsshine-x.service network-online.target
Wants=marsshine-x.service network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/marsshine-stream.sh
Restart=always
RestartSec=10
TimeoutStopSec=30
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/marsshine-reload.service <<'EOF'
[Unit]
Description=Nightly MARSSHINE chromium refresh (memory leak flush)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/marsshine-reload.sh
EOF

cat >/etc/systemd/system/marsshine-reload.timer <<'EOF'
[Unit]
Description=Nightly MARSSHINE refresh at 04:00 UTC

[Timer]
OnCalendar=*-*-* 04:00:00 UTC
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/marsshine-redeploy.service <<'EOF'
[Unit]
Description=Poll Vercel build tag and reload chromium on change

[Service]
Type=oneshot
ExecStart=/usr/local/bin/marsshine-redeploy-check.sh
EOF

cat >/etc/systemd/system/marsshine-redeploy.timer <<'EOF'
[Unit]
Description=Check MARSSHINE build tag every 60 seconds

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now marsshine-x.service
systemctl enable --now marsshine-stream.service
systemctl enable --now marsshine-reload.timer
systemctl enable --now marsshine-redeploy.timer

touch /opt/marsshine/.provisioned
echo "=== marsshine startup complete $(date -u) ==="
