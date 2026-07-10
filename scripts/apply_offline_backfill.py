#!/usr/bin/env python3
"""Apply reviewed PEQdB-to-AutoEq aliases and refresh the offline gap list."""
from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/EQForMac/Resources"
CATALOG_PATH = RESOURCES / "headphones_catalog.json"
AUTOEQ_DIR = RESOURCES / "autoeq"
UNMAPPED_PATH = ROOT / "unmapped_graphs.txt"


# PEQdB display name -> existing extraAutoEQ display name. These are reviewed
# aliases (typography, spacing, historical branding), not fuzzy model matches.
REUSE_ALIASES = {
    "VISION EARS ERLKONIG": "Vision Ears Erlkönig",
    "AUR AUDIO AURE": "AüR Audio Aure",
    "DAISO EARPHONES": "Daiso $2 earphones",
    "FOSTEX TR-X00 PURPLEHEART": "Fostex TH-X00 (purpleheart)",
    "FOSTEX TRX00 MAHOGANY": "Fostex TH-X00 Mahogany",
    "KZ LINGLONG": "KZ Lin Long",
    "KZ LING LONG": "KZ Lin Long",
    "VSONIC VC02": "VSonic VCO2",
    "TANGZU ZHU BA JIE": "TANGZU BaJie",
    "SOUNDCORE SLEEP A20": "Anker Soundcore Sleep A20",
    "RODE NTH-100M": "RØDE NTH-100M",
    "RODE NTH100": "RØDE NTH-100",
    "DROP + HIFIMAN HE-4XX": "HIFIMAN HE4XX",
    "DROP PANDA": "Massdrop Panda",
    "SINGAPOREAN AIRLINES COMPLIMENTARY IN-EAR": "Singapore Airlines complimentary earphones",
    "SIA COMPLIMENTARY EARPHONES": "Singapore Airlines complimentary earphones",
    "TRALUCENT 1+XPLUS": "Tralucent Audio 1+X plus",
    "FENDER TEN FIVE": "Fender Ten 5",
    "CATEAR MIA": "Cat Ear Audio Mia",
}


# PEQdB display name -> (AutoEq display name, source, upstream directory,
# bundled filename). These files were retrieved from the current AutoEq index.
DOWNLOADED_ALIASES = {
    "BEYERDYNAMIC DT700 PROX": ("Beyerdynamic DT 700 Pro X", "oratory1990", "oratory1990/over-ear/Beyerdynamic DT 700 Pro X", "up_dt700prox.txt"),
    "BEYERDYNAMIC DT900 PROX": ("Beyerdynamic DT 900 Pro X", "oratory1990", "oratory1990/over-ear/Beyerdynamic DT 900 Pro X", "up_dt900prox.txt"),
    "KINERA CELEST PLUSTUS BEAST": ("Kinera Celest Plutus Beast", "Fahryst", "Fahryst/in-ear/Kinera Celest Plutus Beast", "up_plutus_beast.txt"),
    "7TH ACOUSTIC PROXIMA": ("7th Acoustics Proxima", "Super Review", "Super Review/in-ear/7th Acoustics Proxima", "up_proxima.txt"),
    "KIWI EARS SINGNOLO": ("Kiwi Ears Singolo", "Filk", "Filk/in-ear/Kiwi Ears Singolo", "up_singolo.txt"),
    "AUDIOSENSE T100": ("Audiosense DT100", "crinacle", "crinacle/711 in-ear/Audiosense DT100", "up_dt100.txt"),
    "APPLE AIRPOD MAX": ("Apple AirPods Max", "oratory1990", "oratory1990/over-ear/Apple AirPods Max", "up_airpods_max.txt"),
    "ABYSS AMB-1266 PHI": ("Abyss AB-1266 Phi", "crinacle", "crinacle/GRAS 43AG-7 over-ear/Abyss AB-1266 Phi", "up_ab1266_phi.txt"),
    "MEZE 99 CLASSIC": ("Meze 99 Classics", "oratory1990", "oratory1990/over-ear/Meze 99 Classics", "up_meze99_classics.txt"),
    "FIR AUDIO XENO 6": ("Fir Audio Xenon 6", "crinacle", "crinacle/711 in-ear/Fir Audio Xenon 6", "up_xenon6.txt"),
    "WHIZZER HE1": ("Whizzer HE01", "crinacle", "crinacle/711 in-ear/Whizzer HE01", "up_whizzer_he01.txt"),
    "ES-LABS ES-1A": ("ES Lab ES-1a", "crinacle", "crinacle/GRAS 43AG-7 over-ear/ES Lab ES-1a", "up_eslab_es1a.txt"),
    "TANGZU YUAN XUAN JI": ("TANGZU YuXuanJi", "Jaytiss", "Jaytiss/in-ear/TANGZU YuXuanJi", "up_yuxuanji.txt"),
    "ABYSS 1266 PHI TC": ("Abyss AB1-266 Phi TC", "oratory1990", "oratory1990/over-ear/Abyss AB1-266 Phi TC", "up_ab1266_phi_tc.txt"),
    "ZIIGAAT X FRESH REV ARETE": ("ZiiGaat x Fresh Reviews Arete", "Jaytiss", "Jaytiss/in-ear/ZiiGaat x Fresh Reviews Arete", "up_arete.txt"),
    "ORIOLUS TRAILLI JP": ("Oriolus Traillii", "crinacle", "crinacle/711 in-ear/Oriolus Traillii", "up_traillii.txt"),
    "HIFIMAN JADE 2": ("HIFIMAN Jade II", "oratory1990", "oratory1990/over-ear/HIFIMAN Jade II", "up_jade2.txt"),
    "TRI DACRO": ("TRI Draco", "ToneDeafMonk", "ToneDeafMonk/in-ear/TRI Draco", "up_tri_draco.txt"),
}


def main() -> None:
    catalog = json.loads(CATALOG_PATH.read_text())
    extras = {entry["name"]: entry for entry in catalog.get("extraAutoEQ", [])}
    graphs = {entry["name"]: entry for entry in catalog["graphs"]}
    changed = 0

    for graph_name, extra_name in REUSE_ALIASES.items():
        graph = graphs[graph_name]
        extra = extras[extra_name]
        source_file = AUTOEQ_DIR / extra["file"]
        if not source_file.is_file() or source_file.stat().st_size < 40:
            raise RuntimeError(f"Missing bundled preset: {source_file}")
        if not graph.get("hasEQ"):
            graph.update(
                hasEQ=True,
                file=extra["file"],
                source=extra.get("source", "AutoEq"),
                autoeqName=extra_name,
                path=extra.get("path"),
            )
            changed += 1

    for graph_name, (autoeq_name, source, path, filename) in DOWNLOADED_ALIASES.items():
        graph = graphs[graph_name]
        source_file = AUTOEQ_DIR / filename
        text = source_file.read_text()
        if source_file.stat().st_size < 40 or "Filter" not in text:
            raise RuntimeError(f"Invalid downloaded preset: {source_file}")
        if not graph.get("hasEQ"):
            graph.update(
                hasEQ=True,
                file=filename,
                source=source,
                autoeqName=autoeq_name,
                path=f"{path}/{autoeq_name} ParametricEQ.txt",
            )
            changed += 1

    catalog["withEQ"] = sum(bool(entry.get("hasEQ")) for entry in catalog["graphs"])
    catalog["mode"] = "offline"
    catalog["autoeqIndexSha"] = "c7332a43a6460d0c3bd5aaa05754c52fdf123ba1"
    catalog["reviewedAliasBackfill"] = len(REUSE_ALIASES) + len(DOWNLOADED_ALIASES)
    CATALOG_PATH.write_text(json.dumps(catalog, separators=(",", ":")))

    missing = [entry["name"] for entry in catalog["graphs"] if not entry.get("hasEQ")]
    UNMAPPED_PATH.write_text("\n".join(missing) + ("\n" if missing else ""))
    print(f"updated={changed} withEQ={catalog['withEQ']}/{len(catalog['graphs'])} unmapped={len(missing)}")


if __name__ == "__main__":
    main()
