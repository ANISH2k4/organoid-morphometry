#!/usr/bin/env python3
"""
Seam stitching for Organoid_Analyse_CP.ijm: merge Cellpose objects that were
cut in two by a tile seam of the mosaic scan.

Usage:
    python merge_seams.py masks.tif --out merged.tif
           --rows "y1,y2,..."                       row seams (image px; "-" = none)
           --cols "y0-y1:x1,x2,...;y0-y1:x1,..."    column seams per row of tiles (image px; "-" = none)
           [--scale 0.5] [--tol 3] [--min-frac 0.30]
           [--report merges.csv] [--image flat_half.tif --montage merges.png]

Two objects are merged when they touch each other along a seam line:
  * the shared border (pixels of A directly next to pixels of B) lies within
    --tol px (image px, before --scale) of a seam, and
  * that shared border is at least --min-frac of the shorter object's extent
    along the seam (its bounding-box height for a column seam, width for a row seam).
Merging is transitive (A-B and B-C -> one object). The merged object keeps the
smaller label; unmerged labels are unchanged. The seam positions are those
flattenTiles() found in the macro; --scale is masks px per image px (0.5 for
the half-size Cellpose input).

Output: the merged label image, a CSV of every candidate pair (merged or not),
and, with --image, a montage of the merged groups (one panel each; the pieces
outlined in different colours, the seam as a thin white line).
"""
import argparse, os, sys
import numpy as np
import tifffile


def parse_rows(s):
    s = (s or "").strip()
    if s in ("", "-"):
        return []
    return [int(float(v)) for v in s.split(",") if v.strip() != ""]


def parse_cols(s):
    """'y0-y1:x1,x2;y0-y1:x1' -> list of (y0, y1, [x...])"""
    s = (s or "").strip()
    out = []
    if s in ("", "-"):
        return out
    for part in s.split(";"):
        if ":" not in part:
            continue
        rng, xs = part.split(":", 1)
        y0, y1 = (int(float(v)) for v in rng.split("-"))
        xs = [int(float(v)) for v in xs.split(",") if v.strip() != ""]
        if xs:
            out.append((y0, y1, xs))
    return out


class UF:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, a):
        while self.p[a] != a:
            self.p[a] = self.p[self.p[a]]
            a = self.p[a]
        return a

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            if rb < ra:
                ra, rb = rb, ra
            self.p[rb] = ra           # the smaller label is the root


def touching_rows(lab, e, lo, hi, axis):
    """Pairs of labels touching across edge e (between index e-1 and e along
    `axis`), restricted to positions lo..hi along the other axis.
    Returns (labels_a, labels_b, positions) with positions along the seam."""
    if axis == 1:                     # vertical seam: edge between columns e-1 and e
        A = lab[lo:hi, e - 1]
        B = lab[lo:hi, e]
    else:                             # horizontal seam: edge between rows e-1 and e
        A = lab[e - 1, lo:hi]
        B = lab[e, lo:hi]
    m = (A != B) & (A > 0) & (B > 0)
    pos = np.nonzero(m)[0] + lo
    return A[m], B[m], pos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("masks")
    ap.add_argument("--out", required=True)
    ap.add_argument("--rows", default="-")
    ap.add_argument("--cols", default="-")
    ap.add_argument("--scale", type=float, default=0.5, help="mask px per image px")
    ap.add_argument("--tol", type=float, default=3.0, help="image px: border must lie within this of a seam")
    ap.add_argument("--min-frac", type=float, default=0.30)
    ap.add_argument("--report", default=None)
    ap.add_argument("--image", default=None, help="image the masks belong to (for the montage)")
    ap.add_argument("--montage", default=None)
    a = ap.parse_args()

    lab = tifffile.imread(a.masks)
    if lab.ndim == 3:
        lab = lab[0]
    lab = lab.astype(np.int32)
    H, W = lab.shape
    s = a.scale
    tol = a.tol * s
    rows = parse_rows(a.rows)
    cols = parse_cols(a.cols)

    from scipy import ndimage
    nlab = int(lab.max())
    objs = ndimage.find_objects(lab, max_label=nlab)   # slices per label (index label-1)
    extent = {}                                          # label -> (height, width) in mask px
    for k, sl in enumerate(objs, start=1):
        if sl is not None:
            extent[k] = (sl[0].stop - sl[0].start, sl[1].stop - sl[1].start)

    # ---- collect shared borders near every seam: (pair, seam) -> set of positions along the seam
    shared = {}
    seams = []                                           # (axis, seam_px_image, lo, hi) in mask coords
    for y0, y1, xs in cols:
        lo = int(np.floor(y0 * s)); hi = int(np.ceil(y1 * s))
        lo = max(0, lo); hi = min(H, hi)
        for x in xs:
            seams.append((1, x, lo, hi))
    for y in rows:
        seams.append((0, y, 0, W))
    for (axis, pos_img, lo, hi) in seams:
        c = pos_img * s                                  # seam edge coordinate in mask px
        emin = int(np.ceil(c - tol)); emax = int(np.floor(c + tol))
        for e in range(max(1, emin), min((W if axis == 1 else H) - 1, emax) + 1):
            A, B, P = touching_rows(lab, e, lo, hi, axis)
            for la, lb, p in zip(A.tolist(), B.tolist(), P.tolist()):
                key = (min(la, lb), max(la, lb), axis, pos_img)
                shared.setdefault(key, set()).add(p)

    # ---- decide
    uf = UF(nlab + 1)
    report = []
    for (la, lb, axis, pos_img), positions in sorted(shared.items()):
        ext_a = extent[la][0] if axis == 1 else extent[la][1]     # extent along the seam
        ext_b = extent[lb][0] if axis == 1 else extent[lb][1]
        n = len(positions)
        frac = n / max(1, min(ext_a, ext_b))
        merged = frac >= a.min_frac
        if merged:
            uf.union(la, lb)
        report.append([la, lb, "x" if axis == 1 else "y", pos_img, n / s, ext_a / s, ext_b / s, frac, merged])

    # ---- relabel
    lut = np.arange(nlab + 1, dtype=np.int32)
    for k in range(1, nlab + 1):
        lut[k] = uf.find(k)
    merged_lab = lut[lab]
    groups = {}
    for k in range(1, nlab + 1):
        r = lut[k]
        if r != k or (lut == k).sum() > 1:
            groups.setdefault(int(r), set()).add(k)
    groups = {r: sorted(v) for r, v in groups.items() if len(v) > 1}
    n_merges = sum(len(v) - 1 for v in groups.values())
    n_before = len(extent)
    n_after = len(np.unique(merged_lab)) - (1 if (merged_lab == 0).any() else 0)

    out_dtype = np.uint16 if nlab < 65535 else np.int32
    tifffile.imwrite(a.out, merged_lab.astype(out_dtype))

    if a.report:
        with open(a.report, "w") as f:
            f.write("pair_id,label_a,label_b,axis,seam_px,shared_px,extent_a_px,extent_b_px,frac,merged,new_label\n")
            for i, (la, lb, ax, pos, sh, ea, eb, fr, m) in enumerate(report, start=1):
                f.write(f"{i},{la},{lb},{ax},{pos},{sh:.0f},{ea:.0f},{eb:.0f},{fr:.3f},{int(m)},{int(lut[la]) if m else ''}\n")

    if a.montage and a.image and groups:
        make_montage(a.image, lab, groups, seams, s, a.montage, report)

    print(f"{n_merges} seam merges ({len(report)} candidate pairs, {len(groups)} merged objects): "
          f"{n_before} -> {n_after} objects  ->  {a.out}")


def make_montage(image_path, lab, groups, seams, s, out_path, report):
    from PIL import Image, ImageDraw, ImageFont
    from skimage.segmentation import find_boundaries
    img = tifffile.imread(image_path)
    if img.ndim == 3:
        img = img.max(axis=0) if img.shape[0] < img.shape[-1] else img.max(axis=-1)
    if img.dtype != np.uint8:
        lo, hi = np.percentile(img, [0.15, 99.85])
        img = (np.clip((img.astype(np.float32) - lo) / max(hi - lo, 1e-6), 0, 1) * 255).astype(np.uint8)
    H, W = lab.shape
    colours = [(0, 220, 255), (255, 60, 220), (255, 220, 0), (60, 255, 60), (255, 140, 0), (160, 120, 255)]
    T = 300                                              # panel size
    ncol = 5
    panels = []
    frac_of = {}
    for (la, lb, ax, pos, sh, ea, eb, fr, m) in report:
        if m:
            frac_of[(la, lb)] = max(fr, frac_of.get((la, lb), 0))
    for root, labels in sorted(groups.items()):
        m = np.isin(lab, labels)
        ys, xs = np.nonzero(m)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        side = int(max(y1 - y0, x1 - x0) * 1.3) + 20
        cy, cx = (y0 + y1) // 2, (x0 + x1) // 2
        Y0, X0 = max(0, cy - side // 2), max(0, cx - side // 2)
        Y1, X1 = min(H, Y0 + side), min(W, X0 + side)
        crop = np.stack([img[Y0:Y1, X0:X1]] * 3, axis=-1).copy()
        sub = lab[Y0:Y1, X0:X1]
        for i, k in enumerate(labels):
            b = find_boundaries(sub == k, mode="inner")
            crop[b] = colours[i % len(colours)]
        pil = Image.fromarray(crop).resize((T, T), Image.NEAREST)
        d = ImageDraw.Draw(pil)
        f = T / max(1, (Y1 - Y0))
        fx = T / max(1, (X1 - X0))
        for (axis, pos_img, lo, hi) in seams:
            c = pos_img * s
            if axis == 1 and X0 <= c < X1 and not (hi <= Y0 or lo >= Y1):
                xx = (c - X0) * fx
                d.line([(xx, max(0, (lo - Y0) * f)), (xx, min(T, (hi - Y0) * f))], fill=(255, 255, 255), width=1)
            if axis == 0 and Y0 <= c < Y1:
                yy = (c - Y0) * f
                d.line([(0, yy), (T, yy)], fill=(255, 255, 255), width=1)
        try:
            font = ImageFont.truetype("Arial.ttf", 14)
        except OSError:
            font = ImageFont.load_default()
        fr = max([frac_of.get((min(p, q), max(p, q)), 0) for p in labels for q in labels if p < q] + [0])
        txt = f"{'+'.join(str(k) for k in labels)} -> {root}   frac {fr:.2f}"
        d.rectangle([0, 0, T, 18], fill=(0, 0, 0))
        d.text((3, 2), txt, fill=(255, 255, 255), font=font)
        scale_px = 100 / s                               # 100 image px bar
        d.line([(5, T - 8), (5 + 100 * fx, T - 8)], fill=(255, 255, 255), width=2)
        panels.append(pil)
    n = len(panels)
    nrow = (n + ncol - 1) // ncol
    sheet = Image.new("RGB", (ncol * T, nrow * T), (30, 30, 30))
    for i, p in enumerate(panels):
        sheet.paste(p, ((i % ncol) * T, (i // ncol) * T))
    sheet.save(out_path)


if __name__ == "__main__":
    main()
