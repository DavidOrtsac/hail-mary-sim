#!/bin/bash
# EARTHSHINE-1 VM startup. Runs on first boot (Compute Engine metadata
# startup-script). Idempotent — re-runs on every boot but skips heavy steps
# once /opt/earthshine/.provisioned exists.
#
# What this builds on the VM:
#   /etc/systemd/system/earthshine-x.service        — headless Xorg on :0
#   /etc/systemd/system/earthshine-stream.service   — chromium + ffmpeg → YouTube
#   /etc/systemd/system/earthshine-redeploy.timer   — build-tag poller, every 60s
#
# Metadata it reads:
#   stream-key       — YouTube Live stream key
#   ambient-url      — gs:// path to a long ambient audio MP3

set -euo pipefail
exec > >(tee -a /var/log/earthshine-startup.log) 2>&1
echo "=== earthshine startup $(date -u) ==="

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
mdget() { curl -fsH "Metadata-Flavor: Google" "$META/$1"; }

STREAM_KEY="$(mdget stream-key)"
AMBIENT_URL="$(mdget ambient-url)"
EARTHSHINE_URL="https://earthshine.transcendiant.net/?pov=1"

if [ -f /opt/earthshine/.provisioned ]; then
  echo "already provisioned, ensuring services are up"
  systemctl daemon-reload
  systemctl restart earthshine-x.service earthshine-stream.service
  exit 0
fi

mkdir -p /opt/earthshine /var/lib/earthshine

export DEBIAN_FRONTEND=noninteractive
# Google Chrome stable repo. Reliable headless browser; jammy's chromium-browser
# is a snap stub that breaks under root + a custom --user-data-dir. And gcloud is
# NOT needed on the VM (audio comes from the bucket's public https URL), so the
# google-cloud-cli package (which isn't in the base Ubuntu repos anyway) is gone.
install -d -m 0755 /usr/share/keyrings
# Save the armored key directly (apt accepts .asc in signed-by). Avoids `gpg
# --dearmor`, which fails with "cannot open /dev/tty" when run headless on boot.
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o /usr/share/keyrings/google-chrome.asc
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.asc] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get update
apt-get install -y \
  curl gnupg ca-certificates jq python3 python3-pip \
  xserver-xorg-core xserver-xorg-video-dummy xinit x11-xserver-utils \
  xdotool x11-utils \
  ffmpeg \
  google-chrome-stable

# NVIDIA driver via Ubuntu's apt package. GCP's .run installer is pinned to
# 550.54.15, which will NOT compile against this image's 6.8 kernel (it dies at
# "Building kernel modules"). Ubuntu's packaged -server driver IS built for the
# 6.8 HWE kernel and DKMS-builds + loads cleanly (verified: Tesla T4, 580.x).
echo "installing NVIDIA driver (apt nvidia-driver-550-server), ~3-5 min"
apt-get install -y build-essential dkms "linux-headers-$(uname -r)"
apt-get install -y nvidia-driver-550-server nvidia-utils-550-server
modprobe nvidia 2>/dev/null || true

# Hard gate: a dead GPU means a black stream. Stop here WITHOUT marking the box
# provisioned so the failure is loud (this check is what was missing originally).
if ! nvidia-smi >/dev/null 2>&1; then
  echo "FATAL: NVIDIA driver not functional after install"
  exit 1
fi
echo "NVIDIA OK: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"

# Pull ambient audio loop from the bucket's public https URL (no gcloud needed).
AMBIENT_HTTP="https://storage.googleapis.com/${AMBIENT_URL#gs://}"
curl -fsSL -o /opt/earthshine/ambient.mp3 "$AMBIENT_HTTP"

# Headless NVIDIA Xorg config, written by hand (the apt driver doesn't ship
# nvidia-xconfig). BusID parsed from nvidia-smi; AllowEmptyInitialConfiguration
# lets X start with no monitor attached.
_BUS=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | head -1)
IFS=: read -r _dom _b _df <<< "$_BUS"; _d="${_df%.*}"; _f="${_df#*.}"
XBUSID="PCI:$((16#$_b)):$((16#$_d)):$((16#$_f))"
echo "Xorg BusID: $XBUSID"
cat >/etc/X11/xorg.conf <<XORGCONF
Section "ServerLayout"
    Identifier "layout"
    Screen 0 "screen0"
EndSection
Section "Device"
    Identifier "nvidia"
    Driver     "nvidia"
    BusID      "$XBUSID"
    Option     "AllowEmptyInitialConfiguration" "true"
EndSection
Section "Screen"
    Identifier "screen0"
    Device     "nvidia"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Virtual 1920 1080
    EndSubSection
EndSection
XORGCONF

# === streamer script ===
cat >/usr/local/bin/earthshine-stream.sh <<STREAMSH
#!/bin/bash
set -euo pipefail

export DISPLAY=:0
STREAM_KEY="\$(curl -fsH "Metadata-Flavor: Google" $META/stream-key)"

# Wait for X to be ready (race with earthshine-x.service start).
for i in \$(seq 1 30); do
  xdpyinfo >/dev/null 2>&1 && break
  sleep 1
done

# Chromium. Kiosk mode, no sandbox (we're root in a VM), GPU enabled.
# --user-data-dir is recreated each launch to avoid persistent state corruption.
rm -rf /tmp/chrome-earthshine
google-chrome-stable \\
  --user-data-dir=/tmp/chrome-earthshine \\
  --no-sandbox --no-first-run --noerrdialogs \\
  --disable-infobars --disable-translate --disable-features=TranslateUI \\
  --disable-session-crashed-bubble \\
  --autoplay-policy=no-user-gesture-required \\
  --kiosk \\
  --window-size=1920,1080 --window-position=0,0 \\
  --use-gl=angle --use-angle=gl --ignore-gpu-blocklist \\
  "$EARTHSHINE_URL" &
CHROMIUM_PID=\$!

# The pov auto-launch occasionally loses a cold-start race with chrome's GPU
# process and gets stuck on the launch screen; a page reload clears it. A fixed
# wait can't fix a race, so instead: wait until the GPU proves the heavy scene
# is actually loaded (VRAM > 1.5 GB), reloading the page if we're still on the
# launch screen, so ffmpeg never captures it. Then a short settle.
for _i in \$(seq 1 12); do
  sleep 16
  VRAM=\$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  if [ "\${VRAM:-0}" -gt 1500 ]; then echo "sim rendering, VRAM \${VRAM} MiB"; break; fi
  echo "launch-screen race (VRAM \${VRAM} MiB), reloading page"
  xdotool search --name EARTHSHINE 2>/dev/null | head -1 | xargs -r -I{} xdotool key --window {} F5 || true
done
sleep 12

# When ffmpeg exits, kill chromium so systemd can restart the whole service
# clean rather than leaving an orphan chrome.
trap "kill -TERM \$CHROMIUM_PID 2>/dev/null || true; sleep 2; kill -KILL \$CHROMIUM_PID 2>/dev/null || true" EXIT

exec ffmpeg -hide_banner -loglevel warning \\
  -f x11grab -draw_mouse 0 -video_size 1920x1080 -framerate 30 -i :0.0 \\
  -stream_loop -1 -i /opt/earthshine/ambient.mp3 \\
  -c:v h264_nvenc -preset p4 -profile:v high -rc:v cbr -b:v 6000k -maxrate 6000k -bufsize 12000k -g 60 \\
  -c:a aac -b:a 128k -ar 44100 -ac 2 \\
  -map 0:v:0 -map 1:a:0 \\
  -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \\
  -f flv "rtmp://a.rtmp.youtube.com/live2/\$STREAM_KEY"
STREAMSH
chmod +x /usr/local/bin/earthshine-stream.sh

# === build-tag poller (replaces Cloud Scheduler) ===
cat >/usr/local/bin/earthshine-redeploy-check.sh <<'POLL'
#!/bin/bash
set -euo pipefail
URL="https://earthshine.transcendiant.net/"
STATE=/var/lib/earthshine/build-tag
CURRENT=$(curl -fsSL --max-time 10 "$URL" 2>/dev/null | grep -oE "build r[0-9.]+" | head -1 || true)
[ -z "$CURRENT" ] && exit 0
PREVIOUS=$(cat "$STATE" 2>/dev/null || echo "")
if [ "$CURRENT" != "$PREVIOUS" ]; then
  echo "$CURRENT" > "$STATE"
  if [ -n "$PREVIOUS" ]; then
    # Reload chromium so the new build appears on stream. <30s blip.
    DISPLAY=:0 xdotool search --name "EARTHSHINE" 2>/dev/null \
      | head -1 \
      | xargs -r -I{} xdotool key --window {} F5
    logger -t earthshine "build $PREVIOUS → $CURRENT, reloaded chromium"
  else
    logger -t earthshine "build $CURRENT (first observation, no reload)"
  fi
fi
POLL
chmod +x /usr/local/bin/earthshine-redeploy-check.sh

# === systemd units ===
cat >/etc/systemd/system/earthshine-x.service <<'EOF'
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

cat >/etc/systemd/system/earthshine-stream.service <<'EOF'
[Unit]
Description=EARTHSHINE chromium + ffmpeg → YouTube RTMP
After=earthshine-x.service network-online.target
Wants=earthshine-x.service network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/earthshine-stream.sh
Restart=always
RestartSec=10
TimeoutStopSec=30
KillMode=mixed
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/earthshine-redeploy.service <<'EOF'
[Unit]
Description=Poll Vercel build tag and reload chromium on change

[Service]
Type=oneshot
ExecStart=/usr/local/bin/earthshine-redeploy-check.sh
EOF

cat >/etc/systemd/system/earthshine-redeploy.timer <<'EOF'
[Unit]
Description=Check EARTHSHINE build tag every 60 seconds

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now earthshine-x.service
systemctl enable --now earthshine-stream.service
systemctl enable --now earthshine-redeploy.timer

touch /opt/earthshine/.provisioned
echo "=== earthshine startup complete $(date -u) ==="
