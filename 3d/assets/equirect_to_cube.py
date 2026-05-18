#!/usr/bin/env python3
# Parallel equirect→cube projector. 8 worker processes, one per (texture, face)
# pair queued in a pool. Each face writes a 4096×4096 JPG with bilinear sampling.

import sys, os, math, time
from multiprocessing import Pool, cpu_count
from PIL import Image
import numpy as np

FACE_SIZE = 4096

FACES = {
    'px': lambda u, v: ( np.ones_like(u),       -v,            -u           ),
    'nx': lambda u, v: (-np.ones_like(u),       -v,             u           ),
    'py': lambda u, v: ( u,                      np.ones_like(u),  v        ),
    'ny': lambda u, v: ( u,                     -np.ones_like(u), -v        ),
    'pz': lambda u, v: ( u,                     -v,             np.ones_like(u)),
    'nz': lambda u, v: (-u,                     -v,            -np.ones_like(u)),
}

HERE = os.path.dirname(os.path.abspath(__file__))

# Cache source per-process so we don't re-load for every face.
_src_cache = {}
def get_src(src_path):
    if src_path not in _src_cache:
        img = Image.open(src_path).convert('RGB')
        _src_cache[src_path] = (np.asarray(img, dtype=np.uint8), img.size)
    return _src_cache[src_path]

def project_face(args):
    src_path, base_out, face = args
    out_path = f"{base_out}_{face}.jpg"
    if os.path.exists(out_path):
        return f"skip {out_path}"
    t0 = time.time()
    src_arr, (W, H) = get_src(src_path)

    coord = (np.arange(FACE_SIZE, dtype=np.float32) + 0.5) / FACE_SIZE * 2 - 1
    uu, vv = np.meshgrid(coord, coord)
    fn = FACES[face]
    x, y, z = fn(uu, vv)
    norm = np.sqrt(x*x + y*y + z*z)
    x /= norm; y /= norm; z /= norm
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
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), 'RGB').save(out_path, quality=92, optimize=True)
    return f"{out_path} [{time.time()-t0:.1f}s]"

def main():
    jobs = []
    pairs = [
        ('earth_8k.jpg',        'earth_cube'),
        ('earth_8k_clouds.jpg', 'earth_cube_clouds'),
        ('earth_8k_night.jpg',  'earth_cube_night'),
        ('earth_8k_spec.jpg',   'earth_cube_spec'),
    ]
    for src, base in pairs:
        sp = os.path.join(HERE, src)
        bp = os.path.join(HERE, base)
        if not os.path.exists(sp):
            print(f"skip missing {sp}")
            continue
        for face in FACES.keys():
            jobs.append((sp, bp, face))

    nproc = min(8, cpu_count())
    print(f"Processing {len(jobs)} faces with {nproc} workers...")
    t0 = time.time()
    with Pool(nproc) as pool:
        for msg in pool.imap_unordered(project_face, jobs):
            print(msg, flush=True)
    print(f"Total: {time.time()-t0:.1f}s")

if __name__ == '__main__':
    main()
