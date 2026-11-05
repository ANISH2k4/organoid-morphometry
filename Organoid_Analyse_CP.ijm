// ============================================================
//  Organoid_Analyse_CP.ijm
//  Same as Organoid_Analyse.ijm, but the organoids are FOUND by Cellpose
//  (the built-in cpsam model) instead of by thresholding. Measuring,
//  focus score, the S/O/M/X/F rules and every output file are the same,
//  so Organoid_Review.ijm, Organoid_Sheets.ijm and Organoid_Collect.ijm
//  work unchanged. Organoid_Analyse.ijm stays as the fallback.
//
//  How to run: open the plate in Fiji, then Plugins > Macros > Run... and
//  choose this file. Cellpose runs in the background through exec(); Fiji
//  is busy for a few minutes meanwhile (watch the Log window).
//  After Cellpose, objects that were cut in two by a tile seam are stitched
//  back together (cellpose/merge_seams.py, using the seam positions found by
//  flattenTiles): two objects are merged when they touch along a seam, the
//  shared border lies within a few px of the seam and is at least 30 % of the
//  shorter object's extent along it. The merged pairs are shown in
//  NAME_seam_merges.png and listed in NAME_seam_merges.csv.
//  Needs: the "organoid" conda env with Cellpose, and
//         cellpose/predict_organoid.py + cellpose/merge_seams.py
//         (in the cellpose folder next to this macro).
//
//  From another macro: runMacro(thisFile, outputFolder) skips the dialog
//  (defaults used); "outputFolder|reuse" reuses Cellpose masks already there.
// ============================================================

requires("1.53c");

macroDir = File.getParent(getInfo("macro.filepath"));
// Fiji does not always report the path of the macro being run (it can return the
// start-up script instead): fall back to the project folder when the cellpose
// folder is not next to this file
if (!File.exists(macroDir + File.separator + "cellpose" + File.separator + "predict_organoid.py"))
    macroDir = getDirectory("home") + "organoid_project";
if (!File.exists(macroDir + File.separator + "cellpose" + File.separator + "predict_organoid.py"))
    macroDir = getDirectory("home") + "CLAUDE" + File.separator + "github" + File.separator + "organoid-morphometry";
predictDefault = macroDir + File.separator + "cellpose" + File.separator + "predict_organoid.py";
condaDefault = getDirectory("home") + "miniforge3" + File.separator + "bin" + File.separator + "conda";

// ---------- settings ----------
outDir      = "";
umPerPx     = 1.300;
minArea     = 4000;
maxArea     = 1000000;
flatten     = true;
rollBall    = 150;
circSplit   = 0.80;    // re-fitted 3 Nov 2026 on 174 hand-scored S/O matched to cpsam outlines (12 Aug, 14 Aug, XF P1): 75 % agreement with errors balanced (predicts 47 % O vs 49 % by hand); 0.755 gave 69 % and called only 29 % O. Fits without each plate gave 0.80-0.82
mergedArea  = 120000;
focusMin    = 0.45;    // RELATIVE: F if focus score < 0.45 x the plate's median score. Fitted 3 Nov 2026 on 6 hand-U vs 190 hand S/O/M objects from 3 plates (catches 3/6 U, drops 7/190 S/O/M). A fixed cutoff cannot work: XF P1's median score is 0.68 against 1.0 on 12/14 Aug, and the old fixed 0.55 dropped 48 of its 77 hand-confirmed organoids.
excludeEdge = true;
rimFrac     = 0.58;
seamStitch  = true;    // merge objects that Cellpose cut along a tile seam
seamTol     = 4;       // px: the shared border must lie within this distance of a seam (3 lost real pairs to sub-pixel rounding at half size)
seamFrac    = 0.30;    // ...and be at least this fraction of the shorter object's extent along the seam
condaExe    = condaDefault;
condaEnv    = "organoid";
predictPy   = predictDefault;
reuseMasks  = false;

arg = String.trim(getArgument());
if (arg != "") {
    parts = split(arg, "|");
    outDir = parts[0];
    if (parts.length > 1) reuseMasks = (String.trim(parts[1]) == "reuse");
} else {
    Dialog.create("Organoid Analyse (Cellpose) - settings");
    Dialog.addMessage("Analyses the image that is open in Fiji.");
    Dialog.addDirectory("Output folder (results)", "");
    Dialog.addNumber("Pixel size (um/pixel)", umPerPx, 3, 8, "um/px");
    Dialog.addNumber("Minimum object area", minArea, 0, 8, "um^2");
    Dialog.addNumber("Maximum object area", maxArea, 0, 8, "um^2");
    Dialog.addCheckbox("Flatten tile seams (equalise each microscope tile's background)", flatten);
    Dialog.addNumber("Rolling ball radius (used for the focus score)", rollBall, 0, 8, "px");
    Dialog.addNumber("Circularity split (organoid if below)", circSplit, 3, 8, "");
    Dialog.addNumber("Merged-cluster area cutoff", mergedArea, 0, 8, "um^2");
    Dialog.addNumber("Focus cutoff, as a fraction of the plate's median focus score (below = out of focus, not counted)", focusMin, 2, 6, "");
    Dialog.addCheckbox("Exclude objects touching image edge", excludeEdge);
    Dialog.addNumber("Well-rim cutoff: debris if further from the centre than this fraction of the width", rimFrac, 2, 6, "");
    Dialog.addCheckbox("Stitch objects cut by a tile seam (merge pairs that touch along a seam)", seamStitch);
    Dialog.addNumber("   stitching: shared border within this distance of the seam", seamTol, 0, 6, "px");
    Dialog.addNumber("   stitching: shared border at least this fraction of the shorter object's extent along the seam", seamFrac, 2, 6, "");
    Dialog.addFile("conda program", condaExe);
    Dialog.addString("conda environment", condaEnv);
    Dialog.addFile("predict_organoid.py", predictPy);
    Dialog.addCheckbox("Reuse Cellpose masks already in the output folder (skip Cellpose)", reuseMasks);
    Dialog.show();
    outDir      = Dialog.getString();
    umPerPx     = Dialog.getNumber();
    minArea     = Dialog.getNumber();
    maxArea     = Dialog.getNumber();
    flatten     = Dialog.getCheckbox();
    rollBall    = Dialog.getNumber();
    circSplit   = Dialog.getNumber();
    mergedArea  = Dialog.getNumber();
    focusMin    = Dialog.getNumber();
    excludeEdge = Dialog.getCheckbox();
    rimFrac     = Dialog.getNumber();
    seamStitch  = Dialog.getCheckbox();
    seamTol     = Dialog.getNumber();
    seamFrac    = Dialog.getNumber();
    condaExe    = String.trim(Dialog.getString());
    condaEnv    = String.trim(Dialog.getString());
    predictPy   = String.trim(Dialog.getString());
    reuseMasks  = Dialog.getCheckbox();
}

if (nImages == 0) exit("Open the plate image in Fiji first.");
outDir = String.trim(outDir);
if (outDir == "") outDir = getDirectory("image");   // default: next to the image
if (outDir == "") exit("Please choose an output folder.");
if (endsWith(outDir, File.separator)) outDir = substring(outDir, 0, lengthOf(outDir) - 1);
if (!File.isDirectory(outDir)) File.makeDirectory(outDir);
if (!File.exists(condaExe)) exit("conda not found: " + condaExe);
if (!File.exists(predictPy)) exit("predict_organoid.py not found: " + predictPy);
mergePy = File.getParent(predictPy) + File.separator + "merge_seams.py";
if (seamStitch && !File.exists(mergePy)) exit("merge_seams.py not found: " + mergePy);

var bgRef = 0;      // plate background, set by makeNaNCopy (used by focusScore)
var seamRows = "-"; // tile seams found by flattenTiles, for the seam stitching:
var seamCols = "-"; // row seams "y1,y2,..", column seams per row of tiles "y0-y1:x1,x2,..;.." ("-" = none)
var summary = "image\ttotal\tspheroid\torganoid\tmerged\tdebris\tout_of_focus\tpct_organoid\t" +
              "mean_circumference_um\tmean_diameter_um\tmean_area_um2\n";

setBatchMode(true);
run("Set Measurements...",
    "area centroid perimeter fit shape feret's redirect=None decimal=3");
processOpen();
File.saveString(summary, outDir + File.separator + "SUMMARY_all_images.txt");
setBatchMode(false);
print("Outputs in: " + outDir);
print("");
print("NEXT STEP: run Organoid_Review.ijm (or Organoid_Sheets.ijm) to correct the auto calls.");


// ============================================================
function processOpen() {
    roiManager("reset");
    if (isOpen("Results")) { selectWindow("Results"); run("Close"); }

    // work on a copy so the original is untouched
    title = getTitle();
    base  = cleanName(title);
    run("Duplicate...", "title=[" + base + "_copy] duplicate");
    if (nSlices > 1) run("Z Project...", "projection=[Max Intensity]");
    if (bitDepth() == 24) run("8-bit");
    run("Set Scale...", "distance=1 known=" + umPerPx + " unit=um");
    orig = getImageID();
    W = getWidth(); H = getHeight();

    run("Duplicate...", "title=work");
    work = getImageID();
    if (flatten) flattenTiles();

    // --- (2) Cellpose input: the tile-flattened image (32-bit), half size,
    // contrast stretched (0.3 % saturated) and converted to 8-bit, the same
    // way Organoid_Export.ijm makes training tiles
    run("Scale...", "x=0.5 y=0.5 interpolation=Bilinear average create title=cp_in");
    cpScale = getWidth() / W;          // Cellpose px per image px
    run("Enhance Contrast...", "saturated=0.3");
    run("8-bit");
    cpIn = outDir + File.separator + base + "_flat_half.tif";
    maskPath = outDir + File.separator + base + "_flat_half_cp_masks.tif";
    if (reuseMasks && File.exists(maskPath)) {
        saveAs("Tiff", cpIn);          // saved anyway, so the flattening can be checked
        close();
        print(base + ": reusing " + maskPath);
    } else {
        saveAs("Tiff", cpIn);
        close();
        // --- (3) Cellpose: cpsam on the half-size image ---
        print(base + ": running Cellpose (cpsam) - this takes a few minutes...");
        if (File.exists(maskPath)) File.delete(maskPath);
        t0 = getTime();
        cpLog = exec(condaExe, "run", "-n", condaEnv, "python", predictPy, cpIn,
                     "--model", "cpsam", "--downscale", "1", "--masks-only", "--out", outDir);
        if (!File.exists(maskPath)) exit("Cellpose did not produce " + maskPath + "\n\n" + cpLog);
        print("  Cellpose done in " + round((getTime() - t0) / 1000) + " s");
    }

    // --- (3b) seam stitching: merge objects that Cellpose cut along a tile seam ---
    labelsPath = maskPath;
    nMerges = 0;
    mergeCsv = "";
    if (seamStitch) {
        if (seamRows == "-" && seamCols == "-") {
            print("  seam stitching: no tile seams known (flattening off, or no tiles found) - skipped");
        } else {
            mergedPath = outDir + File.separator + base + "_flat_half_cp_masks_merged.tif";
            mergeCsv   = outDir + File.separator + base + "_seam_merges.csv";
            if (File.exists(mergedPath)) File.delete(mergedPath);
            if (File.exists(mergeCsv)) File.delete(mergeCsv);
            mLog = exec(condaExe, "run", "-n", condaEnv, "python", mergePy, maskPath,
                        "--out", mergedPath, "--rows", seamRows, "--cols", seamCols,
                        "--scale", d2s(cpScale, 6), "--tol", "" + seamTol, "--min-frac", "" + seamFrac,
                        "--report", mergeCsv, "--image", cpIn,
                        "--montage", outDir + File.separator + base + "_seam_merges.png");
            if (!File.exists(mergedPath)) exit("Seam stitching failed:\n\n" + mLog);
            mLines = split(String.trim(mLog), "\n");
            mLast = String.trim(mLines[mLines.length - 1]);
            sp = indexOf(mLast, " ");
            if (sp > 0) nMerges = parseInt(substring(mLast, 0, sp));
            if (isNaN(nMerges)) nMerges = 0;
            print("  seam stitching: " + mLast);
            labelsPath = mergedPath;
        }
    }
    // labels that are the result of a merge (for the seam_merged column)
    mergedLabels = ",";
    if (nMerges > 0) {
        mLines = split(File.openAsString(mergeCsv), "\n");
        for (li = 1; li < mLines.length; li++) {
            f = split(mLines[li], ",");
            if (f.length >= 11 && String.trim(f[9]) == "1") mergedLabels = mergedLabels + String.trim(f[10]) + ",";
        }
    }

    // --- focus-score images, exactly as in Organoid_Analyse.ijm ---
    selectImage(work);
    run("Subtract Background...", "rolling=" + rollBall + " light sliding");
    run("Duplicate...", "title=flat");
    flat = getImageID();
    run("Duplicate...", "title=grad");
    run("Gaussian Blur...", "sigma=1");
    run("Find Edges");                 // Sobel gradient magnitude
    grad = getImageID();
    selectImage(work); close();

    // --- (4) masks back to full size (nearest neighbour keeps the labels),
    // one ROI per label; drop small ones and ones touching the image edge
    open(labelsPath);
    half = getImageID();
    run("Scale...", "x=- y=- width=" + W + " height=" + H + " interpolation=None create title=labels");
    lab = getImageID();
    selectImage(half); close();
    selectImage(lab);
    run("Set Scale...", "distance=1 known=" + umPerPx + " unit=um");
    getStatistics(aAll, mAll, minLab, maxLab);
    nSmall = 0; nEdge = 0;
    labOf = newArray(0);               // Cellpose label of ROI i
    for (k = 1; k <= maxLab; k++) {
        setThreshold(k, k);
        run("Create Selection");
        if (selectionType() == -1) continue;
        getSelectionBounds(bx, by, bw, bh);
        if (excludeEdge && (bx <= 0 || by <= 0 || bx + bw >= W || by + bh >= H)) { nEdge++; continue; }
        a = getValue("Area");
        if (a < minArea || a > maxArea) { nSmall++; continue; }
        roiManager("add");
        labOf = Array.concat(labOf, k);
    }
    resetThreshold();
    run("Select None");
    selectImage(lab); close();
    print("  " + maxLab + " Cellpose objects: " + nEdge + " touch the edge, " + nSmall +
          " outside " + minArea + "-" + maxArea + " um^2, " + roiManager("count") + " kept");

    // --- (5) measure every ROI on the original image ---
    // one ROI at a time, so row i of the table is ROI i
    run("Clear Results");
    selectImage(orig);
    for (i = 0; i < roiManager("count"); i++) {
        roiManager("select", i);
        run("Measure");
    }
    run("Select None");

    n = nResults;
    imgW_um = W * umPerPx; imgH_um = H * umPerPx;
    nS = 0; nO = 0; nM = 0; nX = 0; nF = 0;
    sumPer = 0; sumEqd = 0; sumArea = 0;

    nanID = makeNaNCopy(flat);          // other objects must not count as background
    focus = newArray(n);
    for (i = 0; i < n; i++) focus[i] = focusScore(i, flat, grad, nanID);
    selectImage(nanID); close();
    // the cutoff is relative to this plate's median focus score: the absolute
    // score differs between plates (imaging, density), the hand calls do not
    focusMed = 1;
    if (n > 0) {
        fs = Array.copy(focus); Array.sort(fs);
        if (n % 2 == 1) focusMed = fs[(n - 1) / 2]; else focusMed = (fs[n / 2 - 1] + fs[n / 2]) / 2;
        if (focusMed <= 0) focusMed = 1;
    }
    print("  median focus score " + d2s(focusMed, 2) + ": out of focus below " + d2s(focusMin * focusMed, 2));

    // --- (6) measure + pre-classify: same rules, same order as Organoid_Analyse.ijm ---
    for (i = 0; i < n; i++) {
        area = getResult("Area", i);
        circ = getResult("Circ.", i);
        sol  = getResult("Solidity", i);
        per  = getResult("Perim.", i);
        ar   = getResult("AR", i);
        eqd  = 2 * sqrt(area / PI);

        setResult("EquivDiam_um", i, eqd);
        setResult("Circumference_um", i, per);
        sumPer += per; sumEqd += eqd; sumArea += area;

        cls = "";
        cx = getResult("X", i); cy = getResult("Y", i);
        dCentre = sqrt((cx - imgW_um / 2) * (cx - imgW_um / 2) +
                       (cy - imgH_um / 2) * (cy - imgH_um / 2)) / imgW_um;
        if (dCentre > rimFrac) {
            cls = "X"; nX++;          // outside the well: a sliver of the well wall
        } else if (ar > 4 || sol < 0.45) {
            cls = "X"; nX++;          // fibre / thread / very ragged debris - CHECK THIS
        } else if (focus[i] < focusMin * focusMed) {
            cls = "F"; nF++;          // out of focus: not counted
        } else if (area >= mergedArea && sol < 0.80) {
            cls = "M"; nM++;
        } else if (area < minArea * 1.5 && circ < 0.25) {
            cls = "X"; nX++;          // small + irregular: likely debris - CHECK THIS
        } else if (circ < circSplit) {
            cls = "O"; nO++;
        } else {
            cls = "S"; nS++;
        }
        setResult("focus_score", i, focus[i]);
        setResult("focus_rel", i, focus[i] / focusMed);   // score / plate median; F if below the cutoff
        setResult("auto_call", i, cls);
        setResult("your_call", i, "");   // fill in during review
        setResult("cp_label", i, labOf[i]);
        sm = 0;
        if (indexOf(mergedLabels, "," + labOf[i] + ",") >= 0) sm = 1;
        setResult("seam_merged", i, sm);  // 1 = stitched together from pieces cut by a tile seam
    }
    updateResults();
    selectImage(flat); close();
    selectImage(grad); close();

    conf = nS + nO;
    pct  = 0;
    if (conf > 0) pct = 100.0 * nO / conf;
    meanPer = 0; meanEqd = 0; meanArea = 0;
    if (n > 0) { meanPer = sumPer / n; meanEqd = sumEqd / n; meanArea = sumArea / n; }

    // --- (7) same outputs, same names ---
    saveAs("Results", outDir + File.separator + base + "_objects.csv");
    if (roiManager("count") > 0)
        roiManager("Save", outDir + File.separator + base + "_ROIs.zip");

    selectImage(orig);
    run("RGB Color");
    run("Remove Overlay");
    lw = maxOf(2, round(getWidth() / 1500));
    fs = maxOf(14, round(getWidth() / 70));
    setLineWidth(lw);
    setFont("SansSerif", fs, "bold antialiased");
    for (i = 0; i < roiManager("count"); i++) {
        roiManager("select", i);
        c = getResultString("auto_call", i);
        if      (c == "O") setForegroundColor(230, 40, 40);
        else if (c == "S") setForegroundColor(40, 120, 255);
        else if (c == "M") setForegroundColor(255, 150, 0);
        else if (c == "F") setForegroundColor(200, 200, 200);   // out of focus: pale grey
        else               setForegroundColor(130, 130, 130);
        run("Draw", "slice");
        Roi.getBounds(bx, by, bw, bh);
        setJustification("left");
        drawString("" + (i + 1), bx, maxOf(fs, by - 2));
    }
    run("Select None");
    saveAs("PNG", outDir + File.separator + base + "_overlay.png");
    close();

    summary = summary + base + "\t" + n + "\t" + nS + "\t" + nO + "\t" +
              nM + "\t" + nX + "\t" + nF + "\t" + d2s(pct, 1) + "\t" +
              d2s(meanPer, 1) + "\t" + d2s(meanEqd, 1) + "\t" + d2s(meanArea, 0) + "\n";

    print(base + ":  " + n + " objects   S=" + nS + " O=" + nO +
          " M=" + nM + " X=" + nX + " F(out of focus)=" + nF + "   auto %organoid=" + d2s(pct, 1) +
          "   mean circumference=" + d2s(meanPer, 1) + " um   seam merges=" + nMerges);
}

// ------------------------------------------------------------
// The functions below are identical to those in Organoid_Analyse.ijm
// (the macro language has no import). Keep the two copies in sync.
// ------------------------------------------------------------
// Focus score of ROI k: mean gradient in a band round the outline / contrast.
// nanID is a copy of the flat image in which every object is NaN, so a
// neighbour lying in the background ring is ignored instead of dragging
// the background down (which used to inflate the score in crowded areas).
function focusScore(k, flatID, gradID, nanID) {
    // band = (ROI grown 4 px) minus (ROI shrunk 4 px), on the gradient image
    selectImage(gradID);
    roiManager("select", k);
    run("Enlarge...", "enlarge=4 pixel");
    getStatistics(aOut, mOut);
    roiManager("select", k);
    run("Enlarge...", "enlarge=-4 pixel");
    getStatistics(aIn, mIn);
    if (aOut - aIn <= 0) return 0;
    band = (mOut * aOut - mIn * aIn) / (aOut - aIn);
    // contrast: interior (ROI shrunk 4 px) minus background ring 8..30 px out
    selectImage(flatID);
    roiManager("select", k);
    run("Enlarge...", "enlarge=-4 pixel");
    getStatistics(aI, mI);
    selectImage(nanID);
    roiManager("select", k);
    run("Enlarge...", "enlarge=8 pixel");
    run("Make Band...", "band=22");
    getStatistics(aB, bg);              // NaN pixels (other objects) are left out
    if (isNaN(bg) || aB == 0) bg = bgRef;   // ring entirely inside neighbours: use the plate background
    contrast = bg - mI;                 // light background, dark organoid
    if (contrast < 1) contrast = 1;
    run("Select None");
    return band / contrast;
}

// 32-bit copy of the flat image with every ROI in the manager set to NaN;
// also sets bgRef (median of what is left = the plate background).
function makeNaNCopy(flatID) {
    selectImage(flatID);
    run("Select None");
    run("Duplicate...", "title=flatNaN");
    run("32-bit");
    id = getImageID();
    for (k = 0; k < roiManager("count"); k++) {
        roiManager("select", k);
        setColor(NaN);
        fill();
    }
    run("Select None");
    bgRef = getValue("Median");
    return id;
}

// ------------------------------------------------------------
// Flatten the tiles of a mosaic scan.
// Every tile is lit by the same uneven pattern (brighter in the middle,
// darker and not symmetric towards the edges), so at a seam the background
// jumps and an organoid lying across it is cut by a straight line.
// Scaling whole tiles to a common median (the old method) cannot remove the
// jump, because a tile's edge is not at its median brightness; on the 12 Aug
// plate it made the worst seam jump larger (48 -> 103 grey levels).
// Now: find the rows of tiles, then the column seams of every row on its
// own (the rows of a meander scan are offset from each other), work out
// which part of its tile each visible region shows, estimate the shared
// shading pattern as the per-position median of tile / median(tile) over
// all background tiles, and divide every region by its part of the
// pattern. 12 Aug: worst seam jump 48 -> 25, median jump 27 -> 8.
// The image is left as 32-bit.
function flattenTiles() {
    src = getImageID();
    W = getWidth(); H = getHeight();
    run("Select None");
    ref = getValue("Median");
    if (ref <= 0) return;
    minTile = 300;                 // px: anything narrower is a sliver, not a tile

    // --- 1. rows of tiles ---
    ys = findRowSeams(src);               // row seams first, from jumps measured per column band
    rowY0 = newArray(0); rowY1 = newArray(0);
    for (b = 0; b < ys.length - 1; b++) {
        if (ys[b + 1] - ys[b] < minTile) continue;
        rowY0 = Array.concat(rowY0, ys[b]);
        rowY1 = Array.concat(rowY1, ys[b + 1]);
    }
    nRows = rowY0.length;
    if (nRows < 2) { print("  tiles: none found - image left as is"); return; }
    seamRows = "-";                // row seams, for the seam stitching
    if (ys.length > 2) seamRows = arrToStr(Array.slice(ys, 1, ys.length - 1));

    // --- column seams of every row, and the typical pitch T between them ---
    seamStr = newArray(nRows);     // one "x0,x1,..." string per row (the macro language has no nested arrays)
    gaps = newArray(0);
    for (r = 0; r < nRows; r++) {
        xs = findSeams(src, true, rowY0[r], rowY1[r] - rowY0[r]);
        seamStr[r] = arrToStr(xs);
        for (g = 1; g < xs.length - 2; g++) gaps = Array.concat(gaps, xs[g + 1] - xs[g]);
    }
    T = 0;
    if (gaps.length >= 2) { Array.sort(gaps); T = gaps[floor(gaps.length / 2)]; }
    if (T == 0) { print("  tiles: no regular column seams - image left as is"); return; }

    // --- 2. snap each row's seams to a grid of pitch T; a row whose grid does not
    // start at 0 is a shifted row, whose tiles show their RIGHT part ---
    shifted = newArray(nRows);
    for (r = 0; r < nRows; r++) {
        shifted[r] = false;
        v = seamProfile(src, true, rowY0[r], rowY1[r] - rowY0[r]);
        ad = newArray(v.length - 1);
        for (k = 0; k < v.length - 1; k++) ad[k] = abs(v[k + 1] - v[k]);
        sorted = Array.copy(ad); Array.sort(sorted);
        p90 = sorted[floor(0.9 * ad.length)];
        if (p90 <= 0) p90 = 1e-6;
        // the pitch is not a whole number of pixels (about 1843.5 here), so a grid
        // of whole-pixel pitch drifts off the seams by a pixel or two: score each
        // grid position by the largest jump within 2 px, then snap every seam
        // to its own peak (14 Aug row 2 failed the 3x test without this)
        wad = newArray(ad.length);
        for (k = 0; k < ad.length; k++) {
            wm = 0;
            for (q = maxOf(0, k - 2); q <= minOf(ad.length - 1, k + 2); q++) wm = maxOf(wm, ad[q]);
            wad[k] = wm;
        }
        best = -1; bestO = 0;
        for (o = 1; o <= T; o++) {
            s = 0; m = 0;
            for (x = o; x < v.length - 1; x += T) { s += wad[x - 1]; m++; }
            if (m > 0 && s / m > best) { best = s / m; bestO = o; }
        }
        bestO = bestO % T;
        if (best >= 3 * p90) {
            xs = newArray(0); xs = Array.concat(xs, 0);
            for (x = bestO; x < W; x += T) if (x >= minTile && x <= W - minTile) {
                bx = x; bv = -1;
                for (q = maxOf(1, x - 3); q <= minOf(ad.length, x + 3); q++) if (ad[q - 1] > bv) { bv = ad[q - 1]; bx = q; }
                xs = Array.concat(xs, bx);
            }
            xs = Array.concat(xs, W);
            seamStr[r] = arrToStr(xs);
            // shifted = the grid is offset by a real part of a tile (205 px on these
            // scans), not by the odd pixel of rounding (a grid at 1844 is not shifted)
            shifted[r] = (minOf(bestO, T - bestO) > 0.05 * T);
        }
    }

    // column seams of every row of tiles, for the seam stitching
    seamCols = "-";
    for (r = 0; r < nRows; r++) {
        xs = split(seamStr[r], ",");
        if (xs.length <= 2) continue;
        cs = "" + rowY0[r] + "-" + rowY1[r] + ":" + xs[1];
        for (i = 2; i < xs.length - 1; i++) cs = cs + "," + xs[i];
        if (seamCols == "-") seamCols = cs; else seamCols = seamCols + ";" + cs;
    }

    // log the tile layout, so a wrong one is easy to spot
    for (r = 0; r < nRows; r++) {
        sl = "  tiles: row " + (r + 1) + " (y " + rowY0[r] + "-" + rowY1[r] + "): column seams " + seamStr[r];
        if (shifted[r]) sl = sl + "  shifted";
        print(sl);
    }

    // --- 3. the visible regions and the origin of the tile each one belongs to ---
    tw = 0; th = 0;
    for (r = 0; r < nRows; r++) {
        xs = split(seamStr[r], ",");
        for (i = 0; i < xs.length - 1; i++) tw = maxOf(tw, parseInt(xs[i + 1]) - parseInt(xs[i]));
        th = maxOf(th, rowY1[r] - rowY0[r]);
    }
    rX0 = newArray(0); rX1 = newArray(0); rY0 = newArray(0); rY1 = newArray(0); rOX = newArray(0); rOY = newArray(0);
    for (r = 0; r < nRows; r++) {
        xs = split(seamStr[r], ",");
        for (i = 0; i < xs.length - 1; i++) {
            x0 = parseInt(xs[i]); x1 = parseInt(xs[i + 1]);
            if (x1 - x0 < minTile) continue;
            if (shifted[r]) ox = maxOf(0, x1 - tw); else ox = x0;
            rX0 = Array.concat(rX0, x0); rX1 = Array.concat(rX1, x1);
            rY0 = Array.concat(rY0, rowY0[r]); rY1 = Array.concat(rY1, rowY1[r]);
            rOX = Array.concat(rOX, ox); rOY = Array.concat(rOY, rowY0[r]);
        }
    }
    nReg = rX0.length;

    // --- 4. shading pattern on a coarse grid: per cell, median over the
    // background tiles of tile / median(tile) ---
    f = 32;                                       // px per grid cell
    gw = floor((tw + f - 1) / f); gh = floor((th + f - 1) / f);
    vals = newArray(gw * gh * nReg);
    Array.fill(vals, NaN);
    nGood = 0;
    for (q = 0; q < nReg; q++) {
        selectImage(src);
        makeRectangle(rX0[q], rY0[q], rX1[q] - rX0[q], rY1[q] - rY0[q]);
        med = getValue("Median");
        // a tile whose median is far off is mostly well wall or organoid: not a background sample
        if (med <= 0 || abs(med / ref - 1) > 0.35) continue;
        nGood++;
        run("Duplicate...", "title=reg");
        regID = getImageID();
        run("32-bit");
        run("Divide...", "value=" + med);
        bw = maxOf(1, round((rX1[q] - rX0[q]) / f)); bh = maxOf(1, round((rY1[q] - rY0[q]) / f));
        run("Scale...", "x=- y=- width=" + bw + " height=" + bh + " interpolation=Bilinear average create title=regs");
        smallID = getImageID();
        bx = round((rX0[q] - rOX[q]) / f); by = round((rY0[q] - rOY[q]) / f);
        for (j = 0; j < bh && by + j < gh; j++)
            for (i = 0; i < bw && bx + i < gw; i++)
                vals[((by + j) * gw + (bx + i)) * nReg + q] = getPixel(i, j);
        selectImage(smallID); close();
        selectImage(regID); close();
    }
    Sgrid = newArray(gw * gh);
    tmp = newArray(nReg);
    nCov = 0;
    for (c = 0; c < gw * gh; c++) {
        m = 0;
        for (q = 0; q < nReg; q++) {
            v = vals[c * nReg + q];
            if (!isNaN(v)) { tmp[m] = v; m++; }
        }
        if (m == 0) { Sgrid[c] = NaN; continue; }
        sub = Array.slice(tmp, 0, m); Array.sort(sub);
        if (m % 2 == 1) Sgrid[c] = sub[(m - 1) / 2]; else Sgrid[c] = (sub[m / 2 - 1] + sub[m / 2]) / 2;
        nCov++;
    }
    if (nGood < 4 || nCov < 0.5 * gw * gh) {
        selectImage(src); run("Select None");
        print("  tiles: not enough background tiles - image left as is");
        return;
    }
    // cells no tile covers: fill with the median of the covered cells
    cov = newArray(nCov); m = 0;
    for (c = 0; c < gw * gh; c++) if (!isNaN(Sgrid[c])) { cov[m] = Sgrid[c]; m++; }
    Array.sort(cov);
    if (m % 2 == 1) fillV = cov[(m - 1) / 2]; else fillV = (cov[m / 2 - 1] + cov[m / 2]) / 2;
    for (c = 0; c < gw * gh; c++) if (isNaN(Sgrid[c])) Sgrid[c] = fillV;

    // --- 5. smooth, clamp, scale the pattern up to tile size ---
    newImage("Sgrid", "32-bit black", gw, gh, 1);
    sID = getImageID();
    for (j = 0; j < gh; j++) for (i = 0; i < gw; i++) setPixel(i, j, Sgrid[j * gw + i]);
    run("Gaussian Blur...", "sigma=1.5");
    run("Min...", "value=0.4");
    run("Max...", "value=2");
    run("Scale...", "x=- y=- width=" + tw + " height=" + th + " interpolation=Bilinear create title=Sfull");
    sfID = getImageID();
    selectImage(sID); close();

    // --- 6. divide every region by its part of the pattern ---
    selectImage(src);
    run("Select None");
    run("32-bit");
    for (q = 0; q < nReg; q++) {
        w = rX1[q] - rX0[q]; h = rY1[q] - rY0[q];
        selectImage(sfID);
        makeRectangle(rX0[q] - rOX[q], rY0[q] - rOY[q], w, h);
        run("Duplicate...", "title=Sreg");
        srID = getImageID();
        selectImage(src);
        makeRectangle(rX0[q], rY0[q], w, h);
        run("Duplicate...", "title=reg");
        rgID = getImageID();
        imageCalculator("Divide create 32-bit", rgID, srID);
        resID = getImageID();
        run("Select All");
        run("Copy");
        selectImage(src);
        makeRectangle(rX0[q], rY0[q], w, h);
        run("Paste");
        selectImage(resID); close();
        selectImage(rgID); close();
        selectImage(srID); close();
    }
    selectImage(sfID); close();
    selectImage(src);
    run("Select None");
    print("  tiles: " + nRows + " rows, " + nReg + " tiles (" + nGood + " used for the shading pattern), pitch " + T + " px");
}

function arrToStr(a) {
    s = "" + a[0];
    for (i = 1; i < a.length; i++) s = s + "," + a[i];
    return s;
}

// Brightness profile along x (columns=true) or y of a band of the image:
// the band is shrunk to 100 rows (columns) with averaging, then the MEDIAN
// of those 100 is taken per column (row), so organoids on a seam are ignored.
// off/len select the band (rows off..off+len for columns=true, else columns).
function seamProfile(src, columns, off, len) {
    selectImage(src);
    run("Select None");
    W = getWidth(); H = getHeight();
    if (columns) {
        makeRectangle(0, off, W, len);
        run("Duplicate...", "title=band");
        bandID = getImageID();
        run("Scale...", "x=1.0 y=" + (100.0 / len) + " width=" + W + " height=100 interpolation=Bilinear average create title=prof");
    } else {
        makeRectangle(off, 0, len, H);
        run("Duplicate...", "title=band");
        bandID = getImageID();
        run("Scale...", "x=" + (100.0 / len) + " y=1.0 width=100 height=" + H + " interpolation=Bilinear average create title=prof");
    }
    prof = getImageID();
    n = W; if (!columns) n = H;
    v = newArray(n);
    for (k = 0; k < n; k++) {
        if (columns) makeRectangle(k, 0, 1, 100); else makeRectangle(0, k, 100, 1);
        v[k] = getValue("Median");
    }
    selectImage(prof); close();
    selectImage(bandID); close();
    selectImage(src);
    run("Select None");
    return v;
}

// Returns the seam positions along x (columns=true) or y of a band of the
// image (see seamProfile), including 0 and the image size, so consecutive
// pairs delimit the tiles.
function findSeams(src, columns, off, len) {
    v = seamProfile(src, columns, off, len);
    n = v.length;
    // jumps between neighbours
    ad = newArray(n - 1);
    for (k = 0; k < n - 1; k++) ad[k] = abs(v[k + 1] - v[k]);
    return seamsFromJumps(ad, v);
}

// Row seams of the whole image. On a meander scan the rows of tiles are
// offset from each other, so at a row seam the brightness steps UP under some
// columns of tiles and DOWN under others; a single brightness profile over the
// full width (findSeams) averages these to nearly nothing (XF P1: 0.4 % and
// 0.9 % for two of its four row seams). Here the image is shrunk to 100 column
// bands, the jump between neighbouring rows is taken per band, and the MEDIAN
// of the absolute jumps is used, so the steps cannot cancel and organoids on
// a seam are ignored. 12 Aug, 14 Aug and XF P1: all 4 row seams found, at
// 32-104x the typical jump.
function findRowSeams(src) {
    selectImage(src);
    run("Select None");
    H = getHeight();
    run("Duplicate...", "title=rs_copy");
    cpID = getImageID();
    run("32-bit");
    run("Scale...", "x=- y=- width=100 height=" + H + " interpolation=Bilinear average create title=rs_prof");
    profID = getImageID();
    selectImage(cpID); close();
    selectImage(profID);
    makeRectangle(0, 1, 100, H - 1);
    run("Duplicate...", "title=rs_next");
    nextID = getImageID();
    selectImage(profID);
    makeRectangle(0, 0, 100, H - 1);
    run("Duplicate...", "title=rs_this");
    thisID = getImageID();
    imageCalculator("Difference create 32-bit", nextID, thisID);
    dID = getImageID();
    ad = newArray(H - 1);
    for (k = 0; k < H - 1; k++) { makeRectangle(0, k, 100, 1); ad[k] = getValue("Median"); }
    selectImage(profID);
    lv = newArray(H);
    for (k = 0; k < H; k++) { makeRectangle(0, k, 100, 1); lv[k] = getValue("Median"); }
    selectImage(dID); close();
    selectImage(thisID); close();
    selectImage(nextID); close();
    selectImage(profID); close();
    selectImage(src);
    run("Select None");
    return seamsFromJumps(ad, lv);
}

// Seam positions from the jumps ad[k] (between positions k and k+1) and the
// brightness level lv[k]; includes 0 and the image size.
function seamsFromJumps(ad, lv) {
    n = lv.length;
    sorted = Array.copy(ad); Array.sort(sorted);
    p90 = sorted[floor(0.9 * (n - 1))];
    if (p90 <= 0) p90 = 1e-6;
    // a seam: a single-step jump at least 8x the 90th-percentile jump and
    // at least 1.5% of the local level (real seams are 3-10%), and the peak of its neighbourhood.
    // Tiles are at least 200 px wide, so closer peaks are the same seam.
    seams = newArray(0);
    seams = Array.concat(seams, 0);
    last = -1000;
    for (k = 1; k < n - 2; k++) {
        lvl = maxOf(1e-6, (lv[k] + lv[k + 1]) / 2);
        if (ad[k] >= 8 * p90 && ad[k] >= 0.015 * lvl &&
            ad[k] >= ad[k - 1] && ad[k] >= ad[k + 1] && (k + 1) - last >= 200) {
            seams = Array.concat(seams, k + 1);
            last = k + 1;
        }
    }
    // keep only seams that fit a regular grid: tiles of one mosaic are all
    // the same size, so the gaps between true seams are (near) equal
    inner = Array.slice(seams, 1, seams.length);          // drop the leading 0
    if (inner.length >= 2) {
        gaps = newArray(inner.length - 1);
        for (g = 0; g < gaps.length; g++) gaps[g] = inner[g + 1] - inner[g];
        sg = Array.copy(gaps); Array.sort(sg);
        tile = sg[floor(sg.length / 2)];                   // typical gap
        keep = newArray(0);
        keep = Array.concat(keep, 0);
        for (g = 0; g < inner.length; g++) {
            // a seam is kept if its distance to a neighbouring seam (or to the
            // image border) is a multiple of the tile size, within 4 %
            okSeam = false;
            for (h = 0; h < inner.length; h++) {
                if (h == g) continue;
                r = abs(inner[g] - inner[h]) / tile;
                if (abs(r - round(r)) * tile <= 0.04 * tile + 3) okSeam = true;
            }
            if (inner.length == 1) okSeam = true;
            if (okSeam) keep = Array.concat(keep, inner[g]);
        }
        seams = keep;
    }
    seams = Array.concat(seams, n);
    return seams;
}

// turn an image title like "12th aug org.czi - 12th aug org.czi #01"
// into a safe file-name stem like "12th aug org"
function cleanName(t) {
    // keep the scene/series number of a multi-scene file: "... #03" -> "_03"
    scene = "";
    k = lastIndexOf(t, "#");
    if (k >= 0) {
        scene = String.trim(substring(t, k + 1));
        d = lastIndexOf(scene, ".");         // "#01.tif" -> "01"
        if (d > 0) scene = substring(scene, 0, d);
        scene = "_" + scene;
    }
    k = indexOf(t, " - ");
    if (k > 0) t = substring(t, 0, k);
    k = lastIndexOf(t, ".");
    if (k > 0) t = substring(t, 0, k);
    t = String.trim(t) + scene;
    t = replace(t, "[/\\\\:*?\"<>|#]", "_");
    return t;
}
