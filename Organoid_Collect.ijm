// ============================================================
//  Organoid_Collect.ijm
//  Gathers every *_SCORED.txt in a folder (and its sub-folders) into
//  ONE tab-separated table: one row per image, ready for Excel / Prism.
//
//  Run it after you have reviewed all the plates.
//  Output: ALL_PLATES_scored.txt in the folder you choose.
// ============================================================

requires("1.53c");

Dialog.create("Organoid Collect");
Dialog.addDirectory("Folder containing the *_SCORED.txt files (sub-folders are searched too)", "");
Dialog.show();
root = String.trim(Dialog.getString());
if (root == "" || !File.isDirectory(root)) exit("Please choose a folder.");
if (endsWith(root, File.separator)) root = substring(root, 0, lengthOf(root) - 1);

keys = newArray("image", "status", "total_objects", "reviewed", "spheroid", "organoid",
                "merged", "debris", "out_of_focus", "uncertain", "confident_n", "pct_organoid",
                "pct_spheroid", "pct_usable", "mean_circumference_um_all",
                "mean_circumference_um_spheroid", "mean_circumference_um_organoid",
                "outlines_redrawn");
header = "file";
for (k = 0; k < keys.length; k++) header = header + "\t" + keys[k];
out = header + "\n";
files = newArray(0);
files = findScored(root, files);
for (f = 0; f < files.length; f++) {
    txt = File.openAsString(files[f]);
    lines = split(txt, "\n");
    row = File.getName(files[f]);
    for (k = 0; k < keys.length; k++) {
        val = "";
        for (l = 0; l < lines.length; l++) {
            parts = split(lines[l], "\t");
            if (parts.length >= 2 && String.trim(parts[0]) == keys[k]) val = String.trim(parts[1]);
        }
        row = row + "\t" + val;
    }
    out = out + row + "\n";
}
File.saveString(out, root + File.separator + "ALL_PLATES_scored.txt");
print("Collected " + files.length + " scored image(s) into " + root + File.separator + "ALL_PLATES_scored.txt");

function findScored(dir, acc) {
    list = getFileList(dir);
    for (i = 0; i < list.length; i++) {
        p = dir + File.separator + list[i];
        if (endsWith(list[i], "/")) {
            acc = findScored(substring(p, 0, lengthOf(p) - 1), acc);
        } else if (endsWith(list[i], "_SCORED.txt")) {
            acc = Array.concat(acc, p);
        }
    }
    return acc;
}
