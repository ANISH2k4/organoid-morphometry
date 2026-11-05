#!/usr/bin/env python3
"""
Train a Cellpose model on organoid tiles made by Organoid_Export.ijm.

Usage:
    python train_organoid.py  /path/to/tiles_folder   [--epochs 100] [--test-frac 0.2]

The tiles folder holds NAME_tNNN_img.tif / NAME_tNNN_masks.tif pairs from
one or more plates. A random 20 % of the tiles is held out as a test set,
and the script prints the agreement on it (average precision at IoU 0.5)
so you get an honest number, not a hopeful one.

Output: models/organoid_<date>  (the trained model file)
"""
import argparse, glob, os, random, sys, datetime
import numpy as np
import tifffile

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tiles")
    ap.add_argument("--epochs", type=int, default=100)
    ap.add_argument("--test-frac", type=float, default=0.2)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--name", default=None)
    a = ap.parse_args()

    from cellpose import models, train, metrics, core
    imgs = sorted(glob.glob(os.path.join(a.tiles, "*_img.tif")))
    if not imgs:
        sys.exit("no *_img.tif tiles in " + a.tiles)
    pairs = [(f, f.replace("_img.tif", "_masks.tif")) for f in imgs]
    pairs = [p for p in pairs if os.path.exists(p[1])]
    random.Random(a.seed).shuffle(pairs)
    ntest = max(1, int(len(pairs) * a.test_frac)) if len(pairs) > 4 else 0
    test, trn = pairs[:ntest], pairs[ntest:]
    print(f"{len(pairs)} tiles: {len(trn)} train, {len(test)} test")

    X  = [tifffile.imread(f) for f, _ in trn]
    Y  = [tifffile.imread(m).astype(np.int32) for _, m in trn]
    Xt = [tifffile.imread(f) for f, _ in test]
    Yt = [tifffile.imread(m).astype(np.int32) for _, m in test]

    gpu = core.use_gpu()
    print("GPU:", gpu)
    model = models.CellposeModel(gpu=gpu)          # start from the built-in cpsam model
    name = a.name or "organoid_" + datetime.datetime.now().strftime("%Y%m%d")
    os.makedirs("models", exist_ok=True)
    path, losses, tlosses = train.train_seg(
        model.net, train_data=X, train_labels=Y,
        test_data=Xt or None, test_labels=Yt or None,
        n_epochs=a.epochs, learning_rate=1e-5, weight_decay=0.1,
        batch_size=1, save_path=".", model_name=name, min_train_masks=1,
    )
    print("saved model:", path)

    if test:
        m2 = models.CellposeModel(gpu=gpu, pretrained_model=str(path))
        pred = [m2.eval(x, diameter=None)[0] for x in Xt]
        ap_, tp, fp, fn = metrics.average_precision(Yt, pred, threshold=[0.5])
        print(f"TEST  organoids found: {int(tp.sum())}  missed: {int(fn.sum())}  false: {int(fp.sum())}")
        print(f"TEST  average precision @IoU0.5: {np.mean(ap_[:,0]):.3f}")

if __name__ == "__main__":
    main()
