#!/usr/bin/env python3
"""Fill missing PEQdB offline EQs from Squiglink (hangout FR is 403)."""
from __future__ import annotations

import hashlib
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/EQForMac/Resources"
AUTOEQ_DIR = RESOURCES / "autoeq"
CATALOG_PATH = RESOURCES / "headphones_catalog.json"
LOG = ROOT / "scripts/fill_progress.log"

UA = {"User-Agent": "Mozilla/5.0 EQForMac-offline-builder/1.1"}
PEQ_KEY = "4_PEAKING_WITH_SHELVES"  # faster bulk generation


def log(msg: str):
    print(msg, flush=True)
    with LOG.open("a") as f:
        f.write(msg + "\n")


def http_get(url: str, timeout: int = 20) -> bytes | None:
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read() if r.status == 200 else None
    except Exception:
        return None


def tokens(s: str) -> list[str]:
    s = s.upper().replace("&", " AND ")
    s = re.sub(r"\([^)]*\)", " ", s)
    s = re.sub(r"[^A-Z0-9]+", " ", s)
    noise = {
        "THE", "AND", "X", "BY", "EDITION", "VERSION", "VER", "WITH", "FOR",
        "OVER", "EAR", "IN", "IEM", "HEADPHONE", "HEADPHONES", "EARPHONE",
        "EARPHONES", "WIRELESS", "UNIVERSAL", "CUSTOM", "STOCK", "TIPS",
        "DEFAULT", "MODE", "PASSIVE", "ACTIVE", "REVIEW", "ACOUSTICS",
    }
    parts: list[str] = []
    for t in s.split():
        if not t or t in noise:
            continue
        parts.extend(re.findall(r"[A-Z]+|\d+", t) or [t])
    return parts


def compact(s: str) -> str:
    return "".join(tokens(s))


def parse_phone_book(data: list, base: str, source: str) -> list[dict]:
    out = []
    for brand in data:
        bname = brand.get("name") or ""
        for phone in brand.get("phones") or []:
            pname = phone.get("name") or ""
            files = phone.get("file")
            if files is None:
                continue
            if isinstance(files, str):
                files = [files]
            sufs = phone.get("suffix") or []
            if not isinstance(sufs, list):
                sufs = []
            for i, f in enumerate(files):
                if not f:
                    continue
                suffix = sufs[i] if i < len(sufs) else ""
                display = f"{bname} {pname} {suffix}".strip()
                out.append(
                    {
                        "display": display,
                        "file": f,
                        "base": base.rstrip("/") + "/",
                        "source": source,
                        "compact": compact(display),
                        "file_compact": compact(f),
                        "tok": tokens(display),
                    }
                )
    return out


def build_index() -> list[dict]:
    index: list[dict] = []
    sources = [
        ("squig.link", "https://squig.link/data/phone_book.json", "https://squig.link/data/"),
    ]
    # Priority Squiglink databases (public FR)
    for user in [
        "crinacle",
        "hypethesonics",
        "precogvision",
        "bakkwatan",
        "fahryst",
        "freeryder05",
        "kr0mka",
        "regancipher",
        "achoreviews",
        "audioamigo",
        "jaytiss",
        "hbb",
        "timmytunes",
        "superreview",
        "listener",
        "in-ear-fidelity",
        "haruto",
        "teedunn",
        "pwrgods",
        "tonedeafmonk",
    ]:
        sources.append(
            (user, f"https://{user}.squig.link/data/phone_book.json", f"https://{user}.squig.link/data/")
        )
        sources.append(
            (
                f"{user}-hp",
                f"https://{user}.squig.link/headphones/data/phone_book.json",
                f"https://{user}.squig.link/headphones/data/",
            )
        )

    # Hangout phone books for name→file mapping only (FR often 403)
    sources += [
        (
            "hangout-711",
            "https://graph.hangout.audio/iem/711/data/phone_book.json",
            "https://graph.hangout.audio/iem/711/data/",
        ),
        (
            "hangout-5128",
            "https://graph.hangout.audio/iem/5128/data/phone_book.json",
            "https://graph.hangout.audio/iem/5128/data/",
        ),
        (
            "hangout-hp",
            "https://graph.hangout.audio/headphones/data/phone_book.json",
            "https://graph.hangout.audio/headphones/data/",
        ),
    ]

    seen = set()
    for source, pb_url, base in sources:
        raw = http_get(pb_url, timeout=12)
        if not raw or len(raw) < 20:
            continue
        try:
            data = json.loads(raw)
            entries = parse_phone_book(data, base, source)
        except Exception:
            continue
        n = 0
        for e in entries:
            key = (e["base"], e["file"])
            if key in seen:
                continue
            seen.add(key)
            index.append(e)
            n += 1
        log(f"  indexed {source}: +{n}")
    log(f"Total FR index: {len(index)}")
    return index


def prefer(ents: list[dict]) -> dict:
    def rank(e):
        s = 0
        if "hangout" in e["source"]:
            s -= 100
        if e["source"] == "squig.link":
            s += 30
        if "crinacle" in e["source"]:
            s += 20
        if "hypethesonics" in e["source"]:
            s += 10
        return s

    return sorted(ents, key=rank, reverse=True)[0]


def find_match(name: str, index: list[dict], by_c: dict, by_fc: dict) -> dict | None:
    c = compact(name)
    if c in by_c:
        return prefer(by_c[c])
    if c in by_fc:
        return prefer(by_fc[c])

    gt = tokens(name)
    if len(gt) < 2:
        return None
    brand = gt[0]
    gset = set(gt)
    best = None
    best_score = 0.0
    for e in index:
        et = e["tok"]
        if not et:
            continue
        # brand match or strong product-code match
        inter = gset & set(et)
        if not inter:
            continue
        if et[0] != brand and e["file_compact"][:3] != c[:3]:
            # allow digit model matches without brand order
            if not any(t.isdigit() and t in inter for t in gset):
                continue
        nonbrand = inter - {brand, "AUDIO"}
        if not nonbrand and len(inter) < 2:
            continue
        recall = len(inter) / len(gset)
        precision = len(inter) / len(et)
        if recall >= 0.8 and precision >= 0.35:
            score = recall + precision
            if "hangout" not in e["source"]:
                score += 0.2
            if score > best_score:
                best_score = score
                best = e
    return best


def load_fr_text(text: str):
    freqs, mags = [], []
    for line in text.splitlines():
        line = line.strip()
        if not line or line[0] in "*#;":
            continue
        parts = line.replace(",", " ").split()
        if len(parts) < 2:
            continue
        try:
            f = float(parts[0])
            m = float(parts[1])
            if 20 <= f <= 20000:
                freqs.append(f)
                mags.append(m)
        except ValueError:
            continue
    if len(freqs) < 30:
        return None
    return np.array(freqs), np.array(mags)


def download_fr(entry: dict):
    base = entry["base"]
    fname = entry["file"]
    channels = []
    for c in [fname + " L.txt", fname + " R.txt", fname + ".txt"]:
        raw = http_get(base + urllib.parse.quote(c), timeout=15)
        if not raw or len(raw) < 200:
            continue
        parsed = load_fr_text(raw.decode("utf-8", "replace"))
        if parsed:
            channels.append(parsed)
        if len(channels) >= 2:
            break
    if not channels:
        return None
    if len(channels) == 1:
        return channels[0]
    (f0, m0), (f1, m1) = channels[0], channels[1]
    return f0, (m0 + np.interp(f0, f1, m1)) / 2


def generate_peq(freqs, mags, target_path: Path) -> str | None:
    from autoeq.frequency_response import FrequencyResponse
    from autoeq.constants import PEQ_CONFIGS

    fr = FrequencyResponse(name="x", frequency=freqs, raw=mags)
    target = FrequencyResponse.read_csv(str(target_path))
    try:
        fr.process(target=target, max_gain=12)
        peqs = fr.optimize_parametric_eq(
            [PEQ_CONFIGS[PEQ_KEY]], fs=48000, max_time=5.0
        )
        out = Path("/tmp/eq_gen/_tmp_peq.txt")
        out.parent.mkdir(parents=True, exist_ok=True)
        fr.write_eqapo_parametric_eq(str(out), peqs)
        text = out.read_text()
        return text if "Filter" in text else None
    except Exception as e:
        log(f"    peq fail: {e}")
        return None


def main():
    LOG.write_text("")
    log("=== Squig/Hangout offline fill ===")
    index = build_index()
    by_c: dict[str, list] = {}
    by_fc: dict[str, list] = {}
    for e in index:
        by_c.setdefault(e["compact"], []).append(e)
        by_fc.setdefault(e["file_compact"], []).append(e)

    catalog = json.loads(CATALOG_PATH.read_text())
    graphs = catalog["graphs"]
    missing = [g for g in graphs if not g.get("hasEQ") or not g.get("file")]
    log(f"Missing EQ: {len(missing)}")

    tdir = Path("/tmp/eq_gen/targets")
    tdir.mkdir(parents=True, exist_ok=True)
    ie = tdir / "harman_ie.csv"
    oe = tdir / "harman_oe.csv"
    if not ie.exists() or ie.stat().st_size < 100:
        ie.write_bytes(
            http_get(
                "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/targets/Harman%20in-ear%202019.csv"
            )
            or b""
        )
    if not oe.exists() or oe.stat().st_size < 100:
        oe.write_bytes(
            http_get(
                "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/targets/Harman%20over-ear%202018.csv"
            )
            or b""
        )

    AUTOEQ_DIR.mkdir(parents=True, exist_ok=True)
    filled = failed = no_match = 0

    for i, g in enumerate(missing):
        name = g["name"]
        match = find_match(name, index, by_c, by_fc)
        if not match:
            no_match += 1
            continue

        # Prefer non-hangout for download
        if "hangout" in match["source"]:
            alts = [
                e
                for e in index
                if "hangout" not in e["source"]
                and (
                    e["compact"] == match["compact"]
                    or e["file_compact"] == match["file_compact"]
                    or compact(e["file"]) == compact(match["file"])
                )
            ]
            if alts:
                match = prefer(alts)

        log(f"[{i+1}/{len(missing)}] {name} -> {match['file']} ({match['source']})")
        fr = download_fr(match)
        if fr is None:
            failed += 1
            log("    FR fail")
            continue
        freqs, mags = fr
        is_oe = bool(
            re.search(
                r"\b(HD\s*\d{3}|DT\s*\d|ATH-M|LCD-|SUNDARA|EDITION XS|OVER-EAR|HEADPHONE)\b",
                name,
                re.I,
            )
        )
        peq_text = generate_peq(freqs, mags, oe if is_oe else ie)
        if not peq_text:
            failed += 1
            continue

        h = hashlib.sha1(f"squig:{name}:{match['file']}".encode()).hexdigest()[:12]
        local = f"{h}.txt"
        (AUTOEQ_DIR / local).write_text(peq_text)
        g["hasEQ"] = True
        g["file"] = local
        g["source"] = f"squig/{match['source']}"
        g["autoeqName"] = match["file"]
        g["path"] = f"generated/{match['source']}/{match['file']}"
        filled += 1

        if filled % 20 == 0:
            catalog["graphs"] = graphs
            catalog["withEQ"] = sum(1 for x in graphs if x.get("hasEQ"))
            CATALOG_PATH.write_text(json.dumps(catalog, separators=(",", ":")))
            log(f"  checkpoint filled={filled}")

    catalog["graphs"] = graphs
    catalog["withEQ"] = sum(1 for x in graphs if x.get("hasEQ"))
    catalog["mode"] = "offline"
    catalog["source"] = (
        "PEQdB names + AutoEq bundled + Squiglink FR→Harman PEQ (hangout names)"
    )
    catalog["squigFilled"] = filled
    CATALOG_PATH.write_text(json.dumps(catalog, separators=(",", ":")))
    still = sum(1 for x in graphs if not x.get("hasEQ"))
    log(
        f"Done filled={filled} failed={failed} no_match={no_match} still={still} withEQ={catalog['withEQ']}/{len(graphs)}"
    )


if __name__ == "__main__":
    main()
