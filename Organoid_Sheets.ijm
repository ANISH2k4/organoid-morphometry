// ============================================================
//  Organoid_Sheets.ijm
//  Makes "contact sheets": one small picture of every detected
//  object, outlined and numbered, tiled 5 x 5 per sheet. Lets a
//  second person score a whole image from a handful of pictures
//  instead of clicking through the review dialog.
//
//  Run Organoid_Analyse.ijm FIRST.
//  Point this at the same image + its _ROIs.zip + its _objects.csv.
//  Output: NAME_sheet_1.jpg, NAME_sheet_2.jpg, ...
//
//  Each tile shows: object number, auto call, area, and the
//  yellow outline the macro measured.
// ============================================================

requires("1.53c");

openDefault = false;
if (nImages > 0) openDefault = true;
Dialog.create("Organoid Sheets - files");
Dialog.addCheckbox("Use the image that is already open in Fiji", openDefault);
Dialog.addFile("...or image file (leave blank if using the open image)", "");
Dialog.addFile("ROI set (_ROIs.zip)", "");
Dialog.addFile("Object table (_objects.csv)", "");
Dialog.addDirectory("Output folder", "");
Dialog.addNumber("Tile size", 400, 0, 6, "px");
Dialog.addNumber("Tiles per row", 5, 0, 6, "");
Dialog.addNumber("Rows per sheet", 5, 0, 6, "");
Dialog.show();
useOpen = Dialog.getCheckbox();
imgPath = String.trim(Dialog.getString());
roiPath = String.trim(Dialog.getString());
csvPath = String.trim(Dialog.getString());
outDir  = String.trim(Dialog.getString());
tile    = Dialog.getNumber();
cols    = Dialog.getNumber();
rows    = Dialog.getNumber();
if (useOpen && nImages == 0) exit("No image is open in Fiji. Open the one you analysed, or untick the box.");
if (!useOpen && !File.exists(imgPath)) exit("Image not found: " + imgPath);
if (!File.exists(roiPath)) exit("ROI set not found: " + roiPath);
if (!File.exists(csvPath)) exit("Object table not found: " + csvPath);
if (outDir == "") exit("Please choose an output folder.");
if (endsWith(outDir, File.separator)) outDir = substring(outDir, 0, lengthOf(outDir) - 1);
if (!File.isDirectory(outDir)) File.makeDirectory(outDir);

roiManager("reset");
if (isOpen("Results")) { selectWindow("Results"); run("Close"); }

if (useOpen) {
    imgID = getImageID();
    base  = cleanName(getTitle());
} else {
    run("Close All");
    open(imgPath);
    imgID = getImageID();
    base  = File.nameWithoutExtension;
}
if (bitDepth() == 24) run("8-bit");
W = getWidth(); H = getHeight();

roiManager("Open", roiPath);
open(csvPath);
tbl = Table.title;          // read the table by name (works in batch mode too)
nRows = Table.size;
n = roiManager("count");
if (n != nRows)
    exit("" + n + " ROIs but " + nRows + " table rows.\n" +
         "The ROI set and the object table do not belong to the same image/run.");
if (n == 0) exit("No objects.");

setBatchMode(true);
perSheet = cols * rows;
nSheets  = floor((n + perSheet - 1) / perSheet);
tileNo   = 0;
for (s = 0; s < nSheets; s++) {
    first = s * perSheet;
    last  = minOf(n, first + perSheet);
    for (i = first; i < last; i++) {
        selectImage(imgID);
        run("Select None");
        roiManager("select", i);
        Roi.getBounds(bx, by, bw, bh);
        // square crop, 30 % margin round the object, never off the image
        side = round(maxOf(bw, bh) * 1.3 + 40);
        if (side > W) side = W;
        if (side > H) side = H;
        x0 = round(bx + bw / 2 - side / 2);
        y0 = round(by + bh / 2 - side / 2);
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x0 + side > W) x0 = W - side;
        if (y0 + side > H) y0 = H - side;
        run("Select None");
        makeRectangle(x0, y0, side, side);
        run("Duplicate...", "title=crop");
        if (bitDepth() == 16) run("Enhance Contrast...", "saturated=0.3");
        run("8-bit");
        run("RGB Color");
        // put the measured outline on the crop
        roiManager("select", i);
        Roi.move(bx - x0, by - y0);
        setForegroundColor(255, 230, 0);      // Draw uses the foreground colour
        setLineWidth(maxOf(2, round(side / 200)));
        run("Draw", "slice");
        run("Select None");
        run("Size...", "width=" + tile + " height=" + tile +
            " depth=1 constrain average interpolation=Bilinear");
        // label strip
        area = Table.get("Area", i, tbl);
        eqd  = 2 * sqrt(area / PI);
        auto = Table.getString("auto_call", i, tbl);
        setColor(0, 0, 0);
        fillRect(0, 0, tile, round(tile * 0.09));
        setFont("SansSerif", round(tile * 0.065), "bold antialiased");
        setColor(255, 230, 0);
        drawString("" + (i + 1) + "   auto " + auto + "   d " + d2s(eqd, 0) + " um",
                   6, round(tile * 0.075));
        rename("tile" + IJ.pad(i + 1, 4));
    }
    nIn = last - first;
    if (nIn == 1) {
        // a sheet with a single object: no stack to montage, save the tile itself
        saveAs("Jpeg", outDir + File.separator + base + "_sheet_" + (s + 1) + ".jpg");
        close();
    } else {
        run("Images to Stack", "name=stack title=tile use");
        r = rows;
        if (nIn < perSheet) r = floor((nIn + cols - 1) / cols);
        run("Make Montage...", "columns=" + cols + " rows=" + r +
            " scale=1 first=1 last=" + nIn + " border=4 use");
        saveAs("Jpeg", outDir + File.separator + base + "_sheet_" + (s + 1) + ".jpg");
        close();                 // montage
        selectImage("stack"); close();
    }
}
setBatchMode(false);
print("Saved " + nSheets + " sheet(s) for " + n + " objects in " + outDir);

function cleanName(t) {
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
