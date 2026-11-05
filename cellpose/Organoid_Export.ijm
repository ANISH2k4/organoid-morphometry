// ============================================================
//  Organoid_Export.ijm
//  Turns ONE reviewed plate into Cellpose training tiles.
//
//  Needs: the image open in Fiji, its *_ROIs_REVIEWED.zip (or _ROIs.zip)
//  and its *_objects_REVIEWED.csv. Objects called S, O or M become
//  labelled organoids; X, F and U are left out, so the model learns to
//  ignore debris and blurry ones.
//
//  Output (in the folder you choose):  NAME_tNNN_img.tif  (8-bit tile)
//                                      NAME_tNNN_masks.tif (label tile)
//  Tiles that contain no organoid are skipped.
// ============================================================

requires("1.53c");

Dialog.create("Organoid Export - training tiles");
Dialog.addFile("ROI set (_ROIs_REVIEWED.zip)", "");
Dialog.addFile("Object table (_objects_REVIEWED.csv)", "");
Dialog.addDirectory("Output folder for tiles", "");
Dialog.addNumber("Tile size", 1024, 0, 6, "px");
Dialog.addNumber("Downscale factor (2 = half size; organoids ~100-800 px are easier at half size)", 2, 0, 4, "");
Dialog.show();
roiPath = String.trim(Dialog.getString());
csvPath = String.trim(Dialog.getString());
outDir  = String.trim(Dialog.getString());
tile    = Dialog.getNumber();
down    = Dialog.getNumber();
if (nImages == 0) exit("Open the plate image first.");
if (!File.exists(roiPath)) exit("ROI set not found: " + roiPath);
if (!File.exists(csvPath)) exit("Object table not found: " + csvPath);
if (outDir == "") exit("Please choose an output folder.");
if (endsWith(outDir, File.separator)) outDir = substring(outDir, 0, lengthOf(outDir) - 1);
if (!File.isDirectory(outDir)) File.makeDirectory(outDir);

setBatchMode(true);
imgID = getImageID();
base  = cleanName(getTitle());
W = getWidth(); H = getHeight();

// --- grey image, 8-bit, contrast stretched ---
run("Duplicate...", "title=grey");
if (nSlices > 1) run("Z Project...", "projection=[Max Intensity]");
if (bitDepth() == 24) run("8-bit");
run("Enhance Contrast...", "saturated=0.3");
run("8-bit");
grey = getImageID();

// --- label image: object k gets value k if its call is S/O/M ---
roiManager("reset");
roiManager("Open", roiPath);
open(csvPath);
tbl = Table.title;
n = roiManager("count");
if (n != Table.size) exit("" + n + " ROIs but " + Table.size + " table rows - wrong pair of files.");
newImage("labels", "16-bit black", W, H, 1);
lab = getImageID();
kept = 0;
for (k = 0; k < n; k++) {
    c = String.trim(Table.getString("your_call", k, tbl));
    if (c == "" || c == "NaN") c = Table.getString("auto_call", k, tbl);
    if (c == "S" || c == "O" || c == "M") {
        selectImage(lab);
        roiManager("select", k);
        setColor(k + 1);
        fill();
        kept++;
    }
}
run("Select None");
print(base + ": " + kept + " of " + n + " objects used as organoids");

// --- downscale both (labels with nearest neighbour so values stay integers) ---
if (down > 1) {
    selectImage(grey);
    run("Scale...", "x=" + (1.0/down) + " y=" + (1.0/down) + " interpolation=Bilinear average create title=grey_s");
    grey2 = getImageID();
    selectImage(lab);
    run("Scale...", "x=" + (1.0/down) + " y=" + (1.0/down) + " interpolation=None create title=lab_s");
    lab2 = getImageID();
} else { grey2 = grey; lab2 = lab; }
selectImage(grey2); W2 = getWidth(); H2 = getHeight();

// --- cut tiles, save pairs that contain at least one organoid ---
t = 0; saved = 0;
for (y = 0; y + tile <= H2 + tile/2; y += tile) {
    for (x = 0; x + tile <= W2 + tile/2; x += tile) {
        x0 = minOf(x, W2 - tile); y0 = minOf(y, H2 - tile);
        selectImage(lab2);
        makeRectangle(x0, y0, tile, tile);
        getStatistics(area, mean, mn, mx);
        if (mx == 0) continue;
        run("Duplicate...", "title=mt");
        saveAs("Tiff", outDir + File.separator + base + "_t" + IJ.pad(t, 3) + "_masks.tif");
        close();
        selectImage(grey2);
        makeRectangle(x0, y0, tile, tile);
        run("Duplicate...", "title=it");
        saveAs("Tiff", outDir + File.separator + base + "_t" + IJ.pad(t, 3) + "_img.tif");
        close();
        saved++; t++;
    }
    if (y + tile >= H2) y = H2 + tile;   // last row done
}
setBatchMode(false);
print("Saved " + saved + " tile pairs to " + outDir);

function cleanName(t) {
    scene = "";
    k = lastIndexOf(t, "#");
    if (k >= 0) scene = "_" + String.trim(substring(t, k + 1));
    k = indexOf(t, " - ");
    if (k > 0) t = substring(t, 0, k);
    k = lastIndexOf(t, ".");
    if (k > 0) t = substring(t, 0, k);
    t = String.trim(t) + scene;
    t = replace(t, "[/\\\\:*?\"<>|# ]", "_");
    return t;
}
