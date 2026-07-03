#!/usr/bin/env python3
"""MARSSHINE equirect -> 6 cube face bake. Runs inside Cloud Build on a
high-CPU GCP worker. NEVER run this locally on the user's Mac Mini.

Input:  /workspace/mars_8k.jpg     (8192 x 4096 equirect)
Output: /workspace/mars_cube_{px,nx,py,ny,pz,nz}.jpg   (4096 x 4096 each)
"""

import os
import time
import math
from multiprocessing import Pool, cpu_count
from PIL import Image
import numpy as np

FACE_SIZE = 4096
SRC_PATH = '/workspace/mars_8k.jpg'
OUT_BASE = '/workspace/mars_cube'

FACES = {
    'px': lambda u, v: ( np.ones_like(u),       -v,                  -u            ),
    'nx': lambda u, v: (-np.ones_like(u),       -v,                   u            ),
    'py': lambda u, v: ( u,                      np.ones_like(u),     v            ),
    'ny': lambda u, v: ( u,                     -np.ones_like(u),    -v            ),
    'pz': lambda u, v: ( u,                     -v,                   np.ones_like(u)),
    'nz': lambda u, v: (-u,                     -v,                  -np.ones_like(u)),
}


def project_face(face):
    out_path = f"{OUT_BASE}_{face}.jpg"
    if os.path.exists(out_path):
        return f"skip {out_path}"
    t0 = time.time()
    img = Image.open(SRC_PATH).convert('RGB')
    src_arr = np.asarray(img, dtype=np.uint8)
    W, H = img.size

    coord = (np.arange(FACE_SIZE, dtype=np.float32) + 0.5) / FACE_SIZE * 2 - 1
    uu, vv = np.meshgrid(coord, coord)
    x, y, z = FACES[face](uu, vv)
    norm = np.sqrt(x * x + y * y + z * z)
    x /= norm
    y /= norm
    z /= norm
    lon = np.arctan2(z, x)
    lat = np.arcsin(np.clip(y, -1.0, 1.0))
    u_eq = (lon + math.pi) / (2 * math.pi) * W
    v_eq = (math.pi / 2 - lat) / math.pi * H

    x0 = np.clip(np.floor(u_eq).astype(np.int32), 0, W - 1)
    x1 = (x0 + 1) % W
    y0 = np.clip(np.floor(v_eq).astype(np.int32), 0, H - 1)
    y1 = np.clip(y0 + 1, 0, H - 1)
    fx = (u_eq - x0)[..., None].astype(np.float32)
    fy = (v_eq - y0)[..., None].astype(np.float32)

    c00 = src_arr[y0, x0].astype(np.float32)
    c10 = src_arr[y0, x1].astype(np.float32)
    c01 = src_arr[y1, x0].astype(np.float32)
    c11 = src_arr[y1, x1].astype(np.float32)
    top = c00 * (1 - fx) + c10 * fx
    bot = c01 * (1 - fx) + c11 * fx
    out = top * (1 - fy) + bot * fy
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), 'RGB').save(
        out_path, quality=92, optimize=True
    )
    return f"{out_path} [{time.time() - t0:.1f}s]"


def main():
    if not os.path.exists(SRC_PATH):
        raise SystemExit(f"missing {SRC_PATH}")
    sz_mb = os.path.getsize(SRC_PATH) / 1e6
    print(f"source: {sz_mb:.1f} MB on {cpu_count()} vCPU", flush=True)
    t0 = time.time()
    with Pool(6) as pool:
        for msg in pool.imap_unordered(project_face, list(FACES.keys())):
            print(msg, flush=True)
    print(f"total: {time.time() - t0:.1f}s", flush=True)


if __name__ == '__main__':
    main()
