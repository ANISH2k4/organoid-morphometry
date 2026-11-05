// ============================================================
//  Organoid_Review.ijm
//  Steps through every detected object, zoomed in, so you can
//  confirm or correct the automatic call.
//
//  Run Organoid_Analyse.ijm FIRST.
//  Point this at the same image + its _ROIs.zip + its _objects.csv
//  (or, when resuming, its _objects_REVIEWED.csv).
//
//  Each object shows a dialog with radio buttons:
//     S spheroid   O budded organoid   M merged cluster
//     X debris     F out of focus      U uncertain       B back one
//     R redraw     -> draw the outline yourself (freehand or oval tool),
//                     click OK, and the object is re-measured. Use it when
//                     the yellow outline misses a pale part, is cut by a
//                     tile seam, or carries a spur. The corrected outlines
//                     are saved as *_ROIs_REVIEWED.zip.
//  The auto call is pre-selected, so for most objects you just hit OK.
//  Tick "save and stop here" to pause. Progress is also autosaved to
//  *_objects_REVIEWED.csv after every object, so Cancel/Esc loses nothing.
//  To resume, give this macro the _REVIEWED.csv as the object table;
//  it starts at the first object you haven't called yet.
//
//  Your calls go into the "your_call" column.
// ============================================================

requires("1.53c");

// arrays written inside functions must be declared global with "var"
var redrawn = newArray(0);

// ---------- settings form (plain ImageJ dialog) ----------
openDefault = false;
if (nImages > 0) openDefault = true;
Dialog.create("Organoid Review - files");
Dialog.addCheckbox("Use the image that is already open in Fiji", openDefault);
Dialog.addFile("...or image file (leave blank if using the open image)", "");
Dialog.addFile("ROI set (_ROIs.zip)", "");
Dialog.addFile("Object table (_objects.csv or _objects_REVIEWED.csv)", "");
Dialog.addDirectory("Output folder", "");
Dialog.addNumber("Start at object # (0 = first unreviewed)", 0, 0, 6, "");
Dialog.addNumber("Zoom padding", 120, 0, 6, "px");
Dialog.addNumber("Pixel size (um/pixel) - same as in Analyse", 1.300, 3, 8, "um/px");
Dialog.show();
useOpen = Dialog.getCheckbox();
imgPath = String.trim(Dialog.getString());
roiPath = String.trim(Dialog.getString());
csvPath = String.trim(Dialog.getString());
outDir  = String.trim(Dialog.getString());
startAt = Dialog.getNumber();
pad     = Dialog.getNumber();
umPerPx = Dialog.getNumber();
if (useOpen && nImages == 0) exit("No image is open in Fiji. Open the one you analysed, or untick the box.");
if (!useOpen && !File.exists(imgPath)) exit("Image not found: " + imgPath);
if (!File.exists(roiPath)) exit("ROI set not found: " + roiPath);
if (!File.exists(csvPath)) exit("Object table not found: " + csvPath);
if (outDir == "") exit("Please choose an output folder.");
if (endsWith(outDir, File.separator)) outDir = substring(outDir, 0, lengthOf(outDir) - 1);

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
run("Set Scale...", "distance=1 known=" + umPerPx + " unit=um");   // so redrawn outlines measure in um

run("Set Measurements...",
    "area centroid perimeter fit shape feret's redirect=None decimal=3");
roiManager("Open", roiPath);
open(csvPath);                  // loads into a table window
tbl = Table.title;              // read/write it by name: works in the GUI and in batch mode

n = roiManager("count");
// FIX: a mismatch means row i no longer describes ROI i - refuse to go on
// rather than silently scoring the wrong objects.
if (n != Table.size)
    exit("" + n + " ROIs but " + Table.size + " table rows.\n" +
         "The ROI set and the object table do not belong to the same image/run.");
if (n == 0) exit("No objects to review.");

outCsv = outDir + File.separator + base + "_objects_REVIEWED.csv";
outRoi = outDir + File.separator + base + "_ROIs_REVIEWED.zip";
redrawn = newArray(n);          // 1 = outline replaced by hand (global, see top)

// FIX: an empty CSV cell comes back as "NaN", not "" - the original check
// never matched, so every dialog defaulted to "S" instead of the auto call.
calls    = newArray(n);
reviewed = newArray(n);         // 1 = a human has called this object
for (i = 0; i < n; i++) {
    v = String.trim(Table.getString("your_call", i, tbl));
    if (v == "" || v == "0" || v == "NaN" || v == "null") {
        calls[i] = Table.getString("auto_call", i, tbl);
        reviewed[i] = 0;
    } else {
        calls[i] = v;
        reviewed[i] = 1;
    }
}

// where to start: explicit object number, else first unreviewed
i = startAt - 1;
if (startAt <= 0) {
    i = 0;
    while (i < n && reviewed[i] == 1) i++;
}
if (i < 0) i = 0;
if (i >= n) {
    showMessage("Nothing left to review - all " + n + " objects already have a call.\n" +
                "Set 'Start at object #' to revisit one.");
    i = n;
}

while (i < n) {
    selectImage(imgID);
    run("Select None");
    roiManager("select", i);
    Roi.getBounds(bx, by, bw, bh);

    // zoom to the object with padding
    x0 = maxOf(0, bx - pad);
    y0 = maxOf(0, by - pad);
    w0 = minOf(getWidth()  - x0, bw + 2 * pad);
    h0 = minOf(getHeight() - y0, bh + 2 * pad);
    makeRectangle(x0, y0, w0, h0);
    run("To Selection");
    roiManager("select", i);

    area = Table.get("Area", i, tbl);
    circ = Table.get("Circ.", i, tbl);
    sol  = Table.get("Solidity", i, tbl);
    eqd  = 2 * sqrt(area / PI);
    auto = Table.getString("auto_call", i, tbl);
    fsc  = "";
    if (Table.columnExists("focus_score")) fsc = "   focus " + d2s(Table.get("focus_score", i, tbl), 2);

    Dialog.create("Object " + (i + 1) + " of " + n);
    flag = "";
    if (redrawn[i] == 1) flag = "   (outline redrawn)";
    Dialog.addMessage("area "   + d2s(area, 0) + " um2" +
                      "   d~"   + d2s(eqd, 0)  + " um\n" +
                      "circ "   + d2s(circ, 3) +
                      "   solidity " + d2s(sol, 3) + fsc + "\n" +
                      "auto call: " + auto + flag);
    choices = newArray("S  spheroid", "O  budded organoid",
                       "M  merged cluster", "X  debris/artifact",
                       "F  out of focus (not counted)",
                       "U  uncertain", "B  back one",
                       "R  redraw the outline by hand");
    def = 0;
    if      (calls[i] == "O") def = 1;
    else if (calls[i] == "M") def = 2;
    else if (calls[i] == "X") def = 3;
    else if (calls[i] == "F") def = 4;
    else if (calls[i] == "U") def = 5;
    Dialog.addRadioButtonGroup("call", choices, 8, 1, choices[def]);
    Dialog.addCheckbox("save and stop here", false);
    Dialog.show();

    pick = Dialog.getRadioButton();
    stop = Dialog.getCheckbox();

    if (startsWith(pick, "R")) {
        redrawOutline(i);           // same object comes back for its call
    } else if (startsWith(pick, "B")) {
        i = maxOf(0, i - 1);
    } else {
        calls[i] = substring(pick, 0, 1);
        reviewed[i] = 1;
        i++;
    }

    // FIX: autosave so Cancel / Esc (which abort the macro) lose nothing
    writeBack();

    if (stop) i = n;
}

writeBack();
roiManager("Save", outRoi);

// --- tally on YOUR calls only ---
nS = 0; nO = 0; nM = 0; nX = 0; nF = 0; nU = 0; nPending = 0;
perS = 0; perO = 0;            // summed circumference of confirmed S / O objects
for (k = 0; k < n; k++) {
    if (reviewed[k] == 0) { nPending++; continue; }
    c = calls[k];
    if (c == "S") perS += Table.get("Perim.", k, tbl);
    if (c == "O") perO += Table.get("Perim.", k, tbl);
    if      (c == "S") nS++;
    else if (c == "O") nO++;
    else if (c == "M") nM++;
    else if (c == "X") nX++;
    else if (c == "F") nF++;
    else               nU++;
}
conf = nS + nO;
pct = 0;
if (conf > 0) pct = 100.0 * nO / conf;
mPerS = 0; mPerO = 0; mPerAll = 0;
if (nS > 0) mPerS = perS / nS;
if (nO > 0) mPerO = perO / nO;
if (conf > 0) mPerAll = (perS + perO) / conf;
nRedrawn = 0;
for (k = 0; k < n; k++) nRedrawn += redrawn[k];
status = "COMPLETE";
if (nPending > 0) status = "INCOMPLETE (" + nPending + " objects not yet reviewed)";

txt = "image\t" + base + "\n" +
      "status\t" + status + "\n" +
      "total_objects\t" + n + "\n" +
      "reviewed\t" + (n - nPending) + "\n" +
      "spheroid\t"  + nS + "\n" +
      "organoid\t"  + nO + "\n" +
      "merged\t"    + nM + "\n" +
      "debris\t"    + nX + "\n" +
      "out_of_focus\t" + nF + "\n" +
      "uncertain\t" + nU + "\n" +
      "confident_n\t" + conf + "\n" +
      "pct_organoid\t" + d2s(pct, 1) + "\n" +
      "pct_spheroid\t" + d2s(100 - pct, 1) + "\n" +
      "pct_usable\t" + d2s(100.0 * conf / n, 1) + "\n" +
      "mean_circumference_um_all\t" + d2s(mPerAll, 1) + "\n" +
      "mean_circumference_um_spheroid\t" + d2s(mPerS, 1) + "\n" +
      "mean_circumference_um_organoid\t" + d2s(mPerO, 1) + "\n" +
      "outlines_redrawn\t" + nRedrawn + "\n";
File.saveString(txt, outDir + File.separator + base + "_SCORED.txt");

print("Saved " + base + "_objects_REVIEWED.csv   [" + status + "]");
print("S=" + nS + " O=" + nO + " M=" + nM + " X=" + nX + " F=" + nF + " U=" + nU);
print("confident n=" + conf + "   %organoid=" + d2s(pct, 1) +
      "   %usable=" + d2s(100.0 * conf / n, 1));


// Let the user draw the outline, replace ROI k with it and re-measure.
function redrawOutline(k) {
    selectImage(imgID);
    run("Select None");
    setTool("freehand");
    waitForUser("Redraw object " + (k + 1),
        "Draw the whole outline with the freehand tool\n" +
        "(or the oval tool for a round one), including any pale part\n" +
        "the yellow outline missed. Then click OK.\n" +
        "Click OK without drawing to keep the old outline.");
    if (selectionType() < 0) return;
    if (selectionType() == 0 || selectionType() == 5 || selectionType() == 9) {
        showMessage("That was a rectangle / line / point. Use the freehand or oval tool.");
        return;
    }
    Roi.getCoordinates(xs, ys);
    roiManager("select", k);                  // manager index = k
    makeSelection("freehand", xs, ys);        // image selection = new outline
    roiManager("update");                     // ROI k := new outline
    roiManager("select", k);
    List.setMeasurements;                     // calibrated measurements of ROI k
    newArea = List.getValue("Area");
    newPer  = List.getValue("Perim.");
    Table.set("Area", k, newArea, tbl);
    Table.set("X", k, List.getValue("X"), tbl);
    Table.set("Y", k, List.getValue("Y"), tbl);
    Table.set("Perim.", k, newPer, tbl);
    Table.set("Major", k, List.getValue("Major"), tbl);
    Table.set("Minor", k, List.getValue("Minor"), tbl);
    Table.set("Angle", k, List.getValue("Angle"), tbl);
    Table.set("Circ.", k, List.getValue("Circ."), tbl);
    Table.set("Feret", k, List.getValue("Feret"), tbl);
    Table.set("MinFeret", k, List.getValue("MinFeret"), tbl);
    Table.set("AR", k, List.getValue("AR"), tbl);
    Table.set("Round", k, List.getValue("Round"), tbl);
    Table.set("Solidity", k, List.getValue("Solidity"), tbl);
    Table.set("EquivDiam_um", k, 2 * sqrt(newArea / PI), tbl);
    Table.set("Circumference_um", k, newPer, tbl);
    redrawn[k] = 1;
    Table.update(tbl);
    roiManager("Save", outRoi);
}

// FIX: only write human calls; unreviewed rows stay blank so a resumed
// session (and anyone reading the CSV) can tell auto from human calls.
function writeBack() {
    for (k = 0; k < n; k++) {
        if (reviewed[k] == 1) Table.set("your_call", k, calls[k], tbl);
        else                  Table.set("your_call", k, "", tbl);
    }
    Table.update(tbl);
    Table.save(outCsv, tbl);
}

// "12th aug org.czi - 12th aug org.czi #01"  ->  "12th aug org"
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
