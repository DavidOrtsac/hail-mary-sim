# EARTHSHINE Livestream, Operations Runbook

The hard-won playbook for the 24/7 EARTHSHINE YouTube stream. Read the **Golden
Rules** before touching anything. They are written in the blood of a multi-hour
debugging spiral on 2026-05-30; every one of them cost real time to learn.

---

## 1. What this is

A 24/7 YouTube livestream of the EARTHSHINE sim (real-time simulated Earth, POV
"EARTHSHINE-1 satellite" view), rendered on a cloud GPU and pushed to YouTube.

**Pipeline:**
```
GCP VM (NVIDIA T4)
  -> headless Xorg :0 on the T4
  -> Google Chrome (kiosk) loading https://earthshine.transcendiant.net/?pov=1
  -> ffmpeg (x11grab screen capture, h264_nvenc GPU encode)
  -> rtmp://a.rtmp.youtube.com/live2/<STREAM_KEY>
  -> YouTube Live
```

---

## 2. Key facts

| Thing | Value |
|---|---|
| VM name | `earthshine-stream` |
| Zone | `us-central1-a` |
| Project | `wifimapproject-489218` |
| Machine | `n1-standard-4` + 1x NVIDIA T4 |
| GPU driver | Ubuntu apt `nvidia-driver-550-server` (resolves to 580.x) |
| Render URL | `https://earthshine.transcendiant.net/?pov=1` (Vercel deploy of `3d/index.html`) |
| Audio | `gs://hail-mary-sim-textures/ops/ambient.mp3` (public; 2 Scott Buckley CC-BY tracks joined) |
| Cost | ~$257/mo on-demand 24/7 (egress to YouTube is FREE) |
| Alert email | `dcastro@thirdteam.org` (NEVER info@contentdash.app) |
| Title/desc/credits | `STREAM_LISTING.txt`, `STREAM_CREDITS.txt` |
| Stream key | a secret; set in YouTube Studio, fed to the VM (see below). Not stored in this repo. |

---

## 3. GOLDEN RULES (do not violate)

1. **NEVER repeatedly restart the stream service or Chrome to "debug."** Each
   Chrome relaunch churns the T4's GPU state. After enough churn, WebGL silently
   dies and the sim is stuck on its launch screen forever, and **relaunching the
   browser does NOT fix it** (the corruption is below the browser).

2. **If the picture is wedged (launch screen / black / frozen), the ONLY fix is a
   full VM reboot.** Not a service restart, not a page reload, not a click.
   ```bash
   gcloud compute instances reset earthshine-stream --zone us-central1-a
   ```
   On a clean boot it renders in ~2 minutes. It also auto-reboots on a crash, so
   it is genuinely fire-and-forget.

3. **"Is the sim actually rendering?" = `nvidia-smi` VRAM > 1500 MiB.**
   - ~389 MiB = stuck on the launch screen, NOT rendering.
   - ~2700-2830 MiB = full Earth scene rendering. Good.
   Do NOT trust "ffmpeg is alive" (it will happily stream a launch screen) or
   YouTube "Excellent" health (that is bitrate only, not content).

4. **Verify with an actual captured frame, never an assumption.**
   ```bash
   DISPLAY=:0 ffmpeg -y -f x11grab -video_size 1920x1080 -i :0.0 -frames:v 1 /tmp/f.png
   # then: gcloud compute scp earthshine-stream:/tmp/f.png /tmp/f.png --zone us-central1-a
   ```

5. **Do NOT reload the YouTube Live Control Room page.** It regenerates the
   stream key, which orphans the VM. If the key changes you must resync it (see
   Troubleshooting).

6. **"Stream now" / Default stream cannot recover from a feed gap.** Any encoder
   restart wedges it on "Preparing stream" forever. To recover: **End stream**,
   then **Go Live** again (the VM keeps feeding, so it starts clean). For real
   resilience use a **Scheduled** broadcast (Manage tab), which tolerates gaps.

---

## 4. Day-to-day operations

```bash
P=wifimapproject-489218; Z=us-central1-a; VM=earthshine-stream

# Is it rendering? (THE health check)
gcloud compute ssh $VM --zone $Z --command \
  "nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader"
#   >1500 MiB = good. ~389 MiB = wedged -> reboot (Rule 2).

# Watch the streamer log
gcloud compute ssh $VM --zone $Z -- "sudo journalctl -u earthshine-stream -f"

# Stop billing (freezes the VM to ~$0)
gcloud compute instances stop $VM --zone $Z
# Resume (services auto-start on boot)
gcloud compute instances start $VM --zone $Z

# Change title / description: YouTube Studio only (editable live, no interruption).
#   Source copy is in 3d/ops/STREAM_LISTING.txt
```

New deploys to `earthshine.transcendiant.net` auto-refresh the stream within 60s
(a build-tag poller F5s Chrome). Deploy during low-traffic hours; an F5 shows a
brief warmup. If a deploy ever wedges the render, reboot (Rule 2).

---

## 5. Deploy from scratch

```bash
# 1. Stage audio (once)
gsutil cp ~/Desktop/hail-mary-sim/beneath_canopy.mp3 gs://.../ambient.mp3   # or the joined Scott Buckley file

# 2. Get a stream key: YouTube Studio -> Go Live -> Stream. Copy the key.
#    (Channel must have live enabled; first-ever enable waits 24h.)

# 3. Provision (prompts for the key hidden; shows cost; asks y/N)
cd ~/Desktop/hail-mary-sim/3d/ops
AMBIENT_GCS_URL="gs://hail-mary-sim-textures/ops/ambient.mp3" ./provision.sh

# 4. ~10 min first boot (driver build + warmup). Verify with Rule 3 / Rule 4.
# 5. In YouTube Studio: set title/description (STREAM_LISTING.txt), category
#    Science & Technology, Made for kids = No, upload thumbnail (earthshine_thumbnail.png).
```

---

## 6. Troubleshooting playbook (symptom -> cause -> fix)

| Symptom | Cause | Fix |
|---|---|---|
| Stream stuck on the **launch/boot screen** (VRAM ~389 MiB) | GPU wedged from Chrome restart churn | **Reboot the VM** (Rule 2). Reloads/clicks do nothing. |
| **Black / frozen** picture | GPU wedge or Chrome crash | Reboot the VM. |
| YouTube **"No data"** | VM not pushing, OR key mismatch | Check `pgrep -af ffmpeg` shows `live2/<key>`. If the key differs from Studio, resync (below). |
| YouTube **"Preparing stream"** forever, health "Excellent" | "Stream now" broadcast wedged by a feed gap | End stream -> Go Live again. Feed is fine; it's a YouTube-side wedge (Rule 6). |
| **Stream key changed** (you reloaded the page) | New key generated | `gcloud compute instances add-metadata earthshine-stream --zone us-central1-a --metadata stream-key="<NEWKEY>"` then `... ssh ... "sudo systemctl restart earthshine-stream"` |
| **Cursor** visible mid-screen | X pointer at screen center | Already fixed: ffmpeg `-draw_mouse 0` + `unclutter`. If it returns, those two. |
| Driver won't build on provision (`Building kernel modules` fails) | GCP's bundled driver too old for the 6.8 kernel | Use apt `nvidia-driver-550-server` (already in startup.sh). |
| First boot installs nothing | `google-cloud-cli` / `chromium-browser` not installable on jammy | Already fixed in startup.sh (curl audio over https; Google Chrome). |

---

## 7. Provisioning gotchas already fixed in `startup.sh`

These are baked in; listed so nobody "fixes" them back to broken:

1. `google-cloud-cli` is NOT in base Ubuntu repos. Don't install it; pull GCS
   objects over their public https URL.
2. jammy `chromium-browser` is a snap stub that breaks headless under root. Use
   Google Chrome stable (`.asc` key via apt `signed-by`, NOT `gpg --dearmor`,
   which fails on `/dev/tty` headless).
3. GCP's `install_gpu_driver.py` is pinned to NVIDIA 550.54.15 which will NOT
   compile against the image's 6.8 kernel. Use apt `nvidia-driver-550-server` +
   `build-essential dkms linux-headers-$(uname -r)`.
4. The apt driver doesn't ship `nvidia-xconfig`; the headless Xorg config is
   hand-written (BusID from nvidia-smi, `AllowEmptyInitialConfiguration`).
5. Chrome WebGL fails under `--enable-features=Vulkan`. Use
   `--use-gl=angle --use-angle=gl --ignore-gpu-blocklist`.
6. `gcloud compute instances reset` is a HARD reset; an unsynced `rm` before it
   is lost. `sync` first, or re-run via `systemd-run`.
7. The launch-screen-stuck bug is a **GPU driver wedge** (see Golden Rule 1/2),
   not the GL flags and not a race. Reboot, do not bounce the browser.
8. Hide the cursor: ffmpeg `-draw_mouse 0` plus `unclutter -idle 0 -root`.

---

_Last updated 2026-05-30 after the first successful go-live._
