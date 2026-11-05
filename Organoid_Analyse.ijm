// ============================================================
//  Organoid_Analyse.ijm
//  Segments organoids, measures morphometry, pre-classifies them.
//
//  Anish / Williams Lab, UEA
//  Pre-classification thresholds calibrated against 755 manually
//  scored organoids (21 Jul P0 plate). Agreement with manual
//  scoring = 70.5%. TREAT AUTO CALLS AS A DRAFT, NOT A RESULT.
//  Correct them with Organoid_Review.ijm before reporting.
// ============================================================

requires("1.53c");

// ---------- settings form (plain ImageJ dialog: works from Plugins>Macros>Run,
// the Script Editor, or a toolbar button alike) ----------
openDefault = false;
if (nImages > 0) openDefault = true;
Dialog.create("Organoid Analyse - settings");
Dialog.addCheckbox("Use the image that is already open in Fiji", openDefault);
Dialog.addMessage("...or choose what to analyse:");
Dialog.addDirectory("Input folder (all images in it)", "");
Dialog.addFile("...or ONE image (leave blank to use the folder)", "");
Dialog.addDirectory("Output folder (results)", "");
Dialog.addNumber("Pixel size (um/pixel)", 1.300, 3, 8, "um/px");
Dialog.addNumber("Minimum object area", 4000, 0, 8, "um^2");
Dialog.addNumber("Maximum object area", 1000000, 0, 8, "um^2");
Dialog.addCheckbox("Flatten tile seams (equalise each microscope tile's background)", true);
Dialog.addNumber("Rolling ball radius", 150, 0, 8, "px");
Dialog.addNumber("Gap closing (bridges breaks in the rim; 0 = off)", 4, 0, 8, "px");
Dialog.addNumber("Spur removal (strips thin specks off the outline; 0 = off)", 3, 0, 8, "px");
Dialog.addCheckbox("Also detect pale / see-through parts by their edges (experimental)", false);
Dialog.addNumber("Circularity split (organoid if below)", 0.65, 3, 8, "");
Dialog.addNumber("Merged-cluster area cutoff", 120000, 0, 8, "um^2");
Dialog.addNumber("Focus cutoff (edge sharpness; below = out of focus, not counted)", 0.45, 2, 6, "");
Dialog.addCheckbox("Exclude objects touching image edge", true);
Dialog.addNumber("Well-rim cutoff: debris if further from the centre than this fraction of the width", 0.58, 2, 6, "");
Dialog.addCheckbox("Save ROI set (.zip) for manual review", true);
Dialog.addCheckbox("Save labelled overlay image", true);
Dialog.show();
useOpen     = Dialog.getCheckbox();
inDir       = Dialog.getString();
inFile      = Dialog.getString();
outDir      = Dialog.getString();
umPerPx     = Dialog.getNumber();
minArea     = Dialog.getNumber();
maxArea     = Dialog.getNumber();
flatten     = Dialog.getCheckbox();
rollBall    = Dialog.getNumber();
closeIter   = Dialog.getNumber();
openIter    = Dialog.getNumber();
useEdges    = Dialog.getCheckbox();
circSplit   = Dialog.getNumber();
mergedArea  = Dialog.getNumber();
focusMin    = Dialog.getNumber();
excludeEdge = Dialog.getCheckbox();
rimFrac     = Dialog.getNumber();
saveRois    = Dialog.getCheckbox();
saveOverlay = Dialog.getCheckbox();

inPath = String.trim(inFile);
if (inPath == "") inPath = String.trim(inDir);
outDir = String.trim(outDir);
if (useOpen && nImages == 0) exit("No image is open in Fiji. Open one, or untick the box and choose a file/folder.");
if (!useOpen && inPath == "") exit("Please choose an input folder or an image, or tick 'use the image already open'.");
if (!useOpen && !File.exists(inPath)) exit("Input not found: " + inPath);
if (outDir == "" && useOpen) outDir = getDirectory("image");   // default: next to the image
if (outDir == "") exit("Please choose an output folder.");
if (endsWith(outDir, File.separator)) outDir = substring(outDir, 0, lengthOf(outDir) - 1);
if (endsWith(inPath, File.separator)) inPath = substring(inPath, 0, lengthOf(inPath) - 1);

// FIX: a variable assigned inside a function is local to that function
// unless it is declared with "var" at top level. Without this, the
// SUMMARY file only ever contained the header row.
var bgRef = 0;      // plate background, set by makeNaNCopy (used by focusScore)
var summary = "image\ttotal\tspheroid\torganoid\tmerged\tdebris\tout_of_focus\tpct_organoid\t" +
              "mean_circumference_um\tmean_diameter_um\tmean_area_um2\n";

setBatchMode(true);
run("Set Measurements...",
    "area centroid perimeter fit shape feret's redirect=None decimal=3");

list = newArray(0);
if (useOpen) {
    list = Array.concat(list, "");          // "" = the image already open
} else if (File.isDirectory(inPath)) {
    raw = getFileList(inPath);
    for (i = 0; i < raw.length; i++) {
        fn = toLowerCase(raw[i]);
        // skip our own *_overlay.png outputs, otherwise a re-run (or
        // outDir == inPath) re-analyses the check images as if they were data
        isOut = endsWith(fn, "_overlay.png");
        isImg = endsWith(fn, ".tif") || endsWith(fn, ".tiff") ||
                endsWith(fn, ".jpg") || endsWith(fn, ".jpeg") ||
                endsWith(fn, ".png") || endsWith(fn, ".czi");   // .czi needs Fiji (Bio-Formats)
        if (isImg && !isOut) {
            list = Array.concat(list, inPath + File.separator + raw[i]);
        }
    }
} else {
    list = Array.concat(list, inPath);
}
if (list.length == 0) exit("No images found in: " + inPath);
if (!File.isDirectory(outDir)) File.makeDirectory(outDir);

for (f = 0; f < list.length; f++) {
    processOne(list[f]);
}

File.saveString(summary, outDir + File.separator + "SUMMARY_all_images.txt");
setBatchMode(false);
print("Done. " + list.length + " image(s) processed.");
print("Outputs in: " + outDir);
print("");
print("NEXT STEP: run Organoid_Review.ijm to correct the auto calls.");


// ============================================================
function processOne(path) {
    roiManager("reset");
    if (isOpen("Results")) { selectWindow("Results"); run("Close"); }

    if (path == "") {
        // use the image already open: work on a copy so the original is untouched
        title = getTitle();
        base  = cleanName(title);
        run("Duplicate...", "title=" + base + "_copy duplicate");
        if (nSlices > 1) run("Z Project...", "projection=[Max Intensity]");
    } else {
        run("Close All");
        open(path);
        title = getTitle();
        base  = File.nameWithoutExtension;
    }

    // --- 8-bit grayscale, calibrated ---
    if (bitDepth() == 24) run("8-bit");
    run("Set Scale...", "distance=1 known=" + umPerPx + " unit=um");

    orig = getImageID();
    run("Duplicate...", "title=work");
    work = getImageID();

    // --- equalise the microscope tiles ---
    // A whole-well scan is a mosaic of tiles, each lit by the same uneven
    // pattern. At a seam the background jumps, and an organoid that
    // straddles it gets cut by a straight line (or a strip of the darker
    // tile is picked up as "object"). The rolling ball cannot fix a jump.
    // flattenTiles() finds the tiles row by row, estimates the shared
    // shading pattern and divides it out (the image becomes 32-bit).
    if (flatten) flattenTiles();

    // --- flatten uneven illumination within tiles ---
    run("Subtract Background...", "rolling=" + rollBall + " light sliding");

    // keep the flattened grey image for the focus measure (below)
    run("Duplicate...", "title=flat");
    flat = getImageID();
    run("Duplicate...", "title=grad");
    run("Gaussian Blur...", "sigma=1");
    run("Find Edges");                 // Sobel gradient magnitude
    grad = getImageID();
    selectImage(work);

    // --- mask A: organoids are DARK on a light field ---
    setOption("BlackBackground", true);
    run("Duplicate...", "title=maskA");
    setAutoThreshold("Otsu");
    run("Convert to Mask");
    maskA = getImageID();

    // --- mask B: pale, see-through parts ---
    // A translucent bud or thin-walled spheroid is only a little darker
    // than the background, so the dark threshold above misses it (the
    // outline then stops at the dark body, or follows only a crescent).
    // But the background is SMOOTH while an organoid, pale or not, has an
    // edge and inner texture. So we also take everything with an edge
    // (Sobel "Find Edges" on a lightly blurred copy), threshold that with
    // the Triangle method (made for the "mostly flat, few bright pixels"
    // histogram an edge image has) and OR it into mask A. Out-of-focus
    // shadows have no sharp edge and are not picked up.
    if (useEdges) {
        selectImage(work);
        run("Duplicate...", "title=maskB");
        run("Gaussian Blur...", "sigma=1");
        run("Find Edges");
        setAutoThreshold("Triangle dark");
        run("Convert to Mask");
        maskB = getImageID();
        // The edge map is a thin band on EITHER side of every edge, so:
        // a small close + fill turns each ringed organoid into a solid
        // blob; a generous Open then deletes thin things that are not
        // organoids (the line along a tile seam, specks of noise stuck to
        // an outline); eroding 3 px pulls the blob back from the outer
        // edge of the band to the true outline, so pale parts are measured
        // at the same size as dark ones.
        run("Options...", "iterations=1 count=1 black do=Close");
        run("Fill Holes");
        run("Options...", "iterations=8 count=1 black do=Open");
        run("Options...", "iterations=3 count=1 black do=Erode");
        run("Options...", "iterations=1 count=1 black do=Nothing");
        imageCalculator("OR create", maskA, maskB);
        rename("mask");
        selectImage(maskA); close();
        selectImage(maskB); close();
    } else {
        selectImage(maskA);
        rename("mask");
    }
    mask = getImageID();

    // --- bridge gaps in the rim ---
    // Fill Holes only fills a ring that is completely closed; one small
    // break in the rim and the centre is lost, so the object is measured
    // as a crescent (or breaks into several pieces). A binary Close
    // (dilate N times, then erode N times) bridges breaks up to ~2N px
    // wide first, so Fill Holes then fills the whole organoid.
    // Trade-off: two organoids closer than ~2N px may be joined (-> M).
    if (closeIter > 0) {
        run("Options...", "iterations=" + closeIter + " count=1 black do=Close");
        run("Options...", "iterations=1 count=1 black do=Nothing");
    }
    run("Fill Holes");

    // --- strip spurs ---
    // A binary Open (erode N, dilate N) removes anything narrower than
    // ~2N px: specks of noise or a tile-seam line stuck to an outline,
    // which otherwise add a false jag to the circumference. Real buds are
    // far wider than that and are unaffected.
    if (openIter > 0) {
        run("Options...", "iterations=" + openIter + " count=1 black do=Open");
        run("Options...", "iterations=1 count=1 black do=Nothing");
    } else {
        run("Open");       // removes single-pixel speckle
    }

    // --- detect ---
    edgeOpt = "";
    if (excludeEdge) edgeOpt = " exclude";
    run("Analyze Particles...",
        "size=" + minArea + "-" + maxArea + " pixel=false" +
        " circularity=0.00-1.00 display clear add" + edgeOpt);

    n = nResults;
    selectImage(orig);
    imgW_um = getWidth() * umPerPx; imgH_um = getHeight() * umPerPx;
    nS = 0; nO = 0; nM = 0; nX = 0; nF = 0;
    sumPer = 0; sumEqd = 0; sumArea = 0;

    // --- focus score per object ---
    // Edge sharpness: mean Sobel gradient in a +-4 px band around the
    // outline, divided by the object's contrast (background minus object
    // interior). A sharp edge scores ~1, a soft out-of-focus edge ~0.1-0.3.
    nanID = makeNaNCopy(flat);          // other objects must not count as background
    focus = newArray(n);
    for (i = 0; i < n; i++) focus[i] = focusScore(i, flat, grad, nanID);
    selectImage(nanID); close();

    // --- measure + pre-classify ---
    for (i = 0; i < n; i++) {
        area = getResult("Area", i);
        circ = getResult("Circ.", i);
        sol  = getResult("Solidity", i);
        per  = getResult("Perim.", i);
        ar   = getResult("AR", i);
        eqd  = 2 * sqrt(area / PI);

        setResult("EquivDiam_um", i, eqd);
        setResult("Circumference_um", i, per);   // perimeter = length around the outline
        sumPer += per; sumEqd += eqd; sumArea += area;

        // ---- rules (in this order) ----
        // 0. centroid outside the well circle -> X (well wall)
        // 1. very long/thin or very ragged    -> X (fibre, debris)
        // 1b. soft edges (focus score low)    -> F out of focus, not counted
        // 2. very large + irregular           -> M merged cluster
        // 3. small + irregular                -> X likely debris
        // 4. circularity below split          -> O budded organoid
        // 5. otherwise                        -> S spheroid
        // The 0.65 split was re-fitted on 275 human-scored S/O objects from
        // three plates (agreement 82%, vs 75% for the old 0.505).
        // Debris is NOT reliably separable by shape: anything small and
        // very irregular is flagged for the human to check.
        // FIX: "call" is a reserved built-in function name in the macro
        // language; using it as a variable aborts the macro on object 1.
        cls = "";
        cx = getResult("X", i); cy = getResult("Y", i);
        dCentre = sqrt((cx - imgW_um / 2) * (cx - imgW_um / 2) +
                       (cy - imgH_um / 2) * (cy - imgH_um / 2)) / imgW_um;
        if (dCentre > rimFrac) {
            cls = "X"; nX++;          // outside the well: a sliver of the well wall
        } else if (ar > 4 || sol < 0.45) {
            cls = "X"; nX++;          // fibre / thread / very ragged debris - CHECK THIS
        } else if (focus[i] < focusMin) {
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
        setResult("auto_call", i, cls);
        setResult("your_call", i, "");   // fill in during review
    }
    updateResults();

    conf = nS + nO;
    pct  = 0;
    if (conf > 0) pct = 100.0 * nO / conf;
    meanPer = 0; meanEqd = 0; meanArea = 0;
    if (n > 0) { meanPer = sumPer / n; meanEqd = sumEqd / n; meanArea = sumArea / n; }

    // --- save per-object table ---
    saveAs("Results", outDir + File.separator + base + "_objects.csv");

    // --- save ROIs for the review macro ---
    if (saveRois && roiManager("count") > 0)
        roiManager("Save", outDir + File.separator + base + "_ROIs.zip");

    // --- labelled overlay ---
    if (saveOverlay) {
        selectImage(orig);
        run("RGB Color");
        run("Remove Overlay");
        // line width and font scale with the image so the overlay is
        // readable on a 9000-px whole-well scan as well as a small field
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
    }

    summary = summary + base + "\t" + n + "\t" + nS + "\t" + nO + "\t" +
              nM + "\t" + nX + "\t" + nF + "\t" + d2s(pct, 1) + "\t" +
              d2s(meanPer, 1) + "\t" + d2s(meanEqd, 1) + "\t" + d2s(meanArea, 0) + "\n";

    print(base + ":  " + n + " objects   S=" + nS + " O=" + nO +
          " M=" + nM + " X=" + nX + " F(out of focus)=" + nF + "   auto %organoid=" + d2s(pct, 1) +
          "   mean circumference=" + d2s(meanPer, 1) + " um");
}

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
    ys = findSeams(src, false, 0, W);     // profile along y over the full width
    rowY0 = newArray(0); rowY1 = newArray(0);
    for (b = 0; b < ys.length - 1; b++) {
        if (ys[b + 1] - ys[b] < minTile) continue;
        rowY0 = Array.concat(rowY0, ys[b]);
        rowY1 = Array.concat(rowY1, ys[b + 1]);
    }
    nRows = rowY0.length;
    if (nRows < 2) { print("  tiles: none found - image left as is"); return; }

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
        best = -1; bestO = 0;
        for (o = 1; o <= T; o++) {
            s = 0; m = 0;
            for (x = o; x < v.length - 1; x += T) { s += ad[x - 1]; m++; }
            if (m > 0 && s / m > best) { best = s / m; bestO = o; }
        }
        bestO = bestO % T;
        if (best >= 3 * p90) {
            xs = newArray(0); xs = Array.concat(xs, 0);
            for (x = bestO; x < W; x += T) if (x >= minTile && x <= W - minTile) xs = Array.concat(xs, x);
            xs = Array.concat(xs, W);
            seamStr[r] = arrToStr(xs);
            shifted[r] = (bestO != 0);
        }
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
    // jumps between neighbours, and their typical size
    ad = newArray(n - 1);
    for (k = 0; k < n - 1; k++) ad[k] = abs(v[k + 1] - v[k]);
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
        lvl = maxOf(1e-6, (v[k] + v[k + 1]) / 2);
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
    if (k >= 0) scene = "_" + String.trim(substring(t, k + 1));
    k = indexOf(t, " - ");
    if (k > 0) t = substring(t, 0, k);
    k = lastIndexOf(t, ".");
    if (k > 0) t = substring(t, 0, k);
    t = String.trim(t) + scene;
    t = replace(t, "[/\\\\:*?\"<>|#]", "_");
    return t;
}
