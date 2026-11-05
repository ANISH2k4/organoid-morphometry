#!/usr/bin/env python3
"""
Find organoids in one image with a Cellpose model.

Usage:
    python predict_organoid.py  image.tif  [--model cpsam | models/organoid_<date>]
                                [--downscale 2] [--diameter 0] [--pixel 1.3] [--out folder]

The image is prepared the same way Organoid_Export.ijm prepares training
tiles (8-bit, contrast stretched with 0.3 % saturated, then downscaled), so a
model trained with train_organoid.py sees what it was trained on. The masks
are scaled back up to the original size before saving.

Output (next to the image, or in --out):
    NAME_cp_masks.tif    label image, object k has value k
    NAME_cp_overlay.png  the image with every object outlined and numbered
    NAME_cp_objects.csv  one row per object: area, equivalent diameter, circularity
With --masks-only just the mask TIFF is written (used by Organoid_Analyse_CP.ijm).
"""
import argparse, os, sys, time
import numpy as np
import tifffile
from PIL import Image, ImageDraw, ImageFont


def to_8bit(img):
    """Like Fiji's Enhance Contrast saturated=0.3, then 8-bit."""
    img = img.astype(np.float32)
    lo, hi = np.percentile(img, [0.15, 99.85])
    return (np.clip((img - lo) / max(hi - lo, 1e-6), 0, 1) * 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--model", default="cpsam", help="cpsam (built-in) or path to a trained model")
    ap.add_argument("--downscale", type=int, default=2, help="same factor as Organoid_Export.ijm (default 2)")
    ap.add_argument("--diameter", type=float, default=0, help="expected diameter in px after downscale; 0 = model default")
    ap.add_argument("--pixel", type=float, default=1.3, help="um per pixel of the original image")
    ap.add_argument("--out", default=None)
    ap.add_argument("--masks-only", action="store_true", help="write only NAME_cp_masks.tif")
    a = ap.parse_args()

    from cellpose import models, core
    from skimage.measure import regionprops
    from skimage.segmentation import find_boundaries
    from skimage.transform import resize

    img = tifffile.imread(a.image)
    if img.ndim == 3:                               # stack or RGB -> max projection
        img = img.max(axis=0) if img.shape[0] < img.shape[-1] else img.max(axis=-1)
    grey = to_8bit(img)
    H, W = grey.shape
    small = grey
    if a.downscale > 1:
        small = (resize(grey, (H // a.downscale, W // a.downscale), order=1,
                        anti_aliasing=True, preserve_range=True)).astype(np.uint8)

    gpu = core.use_gpu()
    print("GPU:", gpu)
    if a.model == "cpsam":
        model = models.CellposeModel(gpu=gpu)       # built-in cpsam
    elif os.path.exists(a.model):
        model = models.CellposeModel(gpu=gpu, pretrained_model=a.model)
    else:
        sys.exit("model not found: " + a.model)

    t0 = time.time()
    masks = model.eval(small, diameter=a.diameter or None)[0]
    print(f"{small.shape[1]}x{small.shape[0]} px in {time.time() - t0:.0f} s")
    if a.downscale > 1:
        masks = resize(masks, (H, W), order=0, preserve_range=True, anti_aliasing=False)
    masks = masks.astype(np.uint16)

    out = a.out or os.path.dirname(os.path.abspath(a.image))
    os.makedirs(out, exist_ok=True)
    base = os.path.join(out, os.path.splitext(os.path.basename(a.image))[0])
    tifffile.imwrite(base + "_cp_masks.tif", masks)
    if a.masks_only:
        print(f"{masks.max()} objects  ->  {base}_cp_masks.tif")
        return

    props = regionprops(masks)
    with open(base + "_cp_objects.csv", "w") as f:
        f.write("label,Area_um2,EquivDiam_um,Circumference_um,Circ.,X_um,Y_um\n")
        for p in props:
            area = p.area * a.pixel ** 2
            per = p.perimeter * a.pixel
            circ = min(1.0, 4 * np.pi * area / per ** 2) if per > 0 else 0
            y, x = p.centroid
            f.write(f"{p.label},{area:.1f},{2 * np.sqrt(area / np.pi):.1f},{per:.1f},"
                    f"{circ:.3f},{x * a.pixel:.1f},{y * a.pixel:.1f}\n")

    # overlay: yellow outlines (3 px) and the label number next to each object
    rgb = np.stack([grey] * 3, axis=-1)
    edge = find_boundaries(masks, mode="outer")
    edge = edge | np.roll(edge, 1, 0) | np.roll(edge, 1, 1)
    rgb[edge] = (255, 220, 0)
    im = Image.fromarray(rgb)
    draw = ImageDraw.Draw(im)
    try:
        font = ImageFont.truetype("Arial.ttf", max(14, W // 80))
    except OSError:
        font = ImageFont.load_default()
    for p in props:
        y0, x0, _, _ = p.bbox
        draw.text((x0, max(0, y0 - font.size - 2)), str(p.label), fill=(0, 255, 255), font=font)
    im.save(base + "_cp_overlay.png")

    print(f"{len(props)} objects  ->  {base}_cp_overlay.png")


if __name__ == "__main__":
    main()
