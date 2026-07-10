#!/usr/bin/env python3
"""Generate offline EQ presets from PEQdB's public graph archive.

Run with AutoEq available, for example:

    uv run --with autoeq==2.2.0 python scripts/fill_from_peqdb_archive.py

PEQdB stores each graph as a scale/offset pair followed by 384 signed
16-bit samples on a logarithmic 20 Hz–20 kHz grid. The graph index embedded
in Studio maps model names to records in that archive.
"""
from __future__ import annotations

import hashlib
import json
import re
import struct
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np
from autoeq.constants import PEQ_CONFIGS
from autoeq.frequency_response import FrequencyResponse


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/EQForMac/Resources"
AUTOEQ_DIR = RESOURCES / "autoeq"
CATALOG_PATH = RESOURCES / "headphones_catalog.json"
UNMAPPED_PATH = ROOT / "unmapped_graphs.txt"

STUDIO_URL = "https://peqdb.com/studio/"
IE_TARGET_URL = (
    "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/targets/"
    "Harman%20in-ear%202019.csv"
)
OE_TARGET_URL = (
    "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/targets/"
    "Harman%20over-ear%202018.csv"
)
USER_AGENT = "EQForMac offline catalog builder/2.0"
RECORD_SIZE = 776
SAMPLE_COUNT = 384


def download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def load_upstream() -> tuple[dict, bytes, str]:
    html = download(STUDIO_URL).decode("utf-8")
    marker = "window.__INDEX__ = "
    start = html.index(marker) + len(marker)
    index, _ = json.JSONDecoder().raw_decode(html[start:])

    match = re.search(
        r'id=["\']graph-data-preload["\'][^>]+href=["\']([^"\']+)', html
    )
    if not match:
        raise RuntimeError("PEQdB graph archive URL not found in Studio")
    archive_url = urllib.parse.urljoin(STUDIO_URL, match.group(1))
    archive = download(archive_url)
    if not archive or len(archive) % RECORD_SIZE:
        raise RuntimeError(f"Invalid PEQdB graph archive ({len(archive)} bytes)")
    return index, archive, archive_url


def build_lookup(index: dict) -> dict[str, list[tuple[str, str, dict]]]:
    lookup: dict[str, list[tuple[str, str, dict]]] = {}
    for kind in ("IE", "OE"):
        for source, models in index[kind].items():
            for name, variants in models.items():
                lookup.setdefault(name, []).append((kind, source, variants))
    return lookup


def decode_graph(archive: bytes, start: int, count: int) -> np.ndarray:
    channels = []
    total_records = len(archive) // RECORD_SIZE
    if start < 0 or count < 1 or start + count > total_records:
        raise RuntimeError(f"Graph record range out of bounds: {start}+{count}")
    for record in range(start, start + count):
        offset = record * RECORD_SIZE
        scale, zero = struct.unpack_from("<ff", archive, offset)
        samples = np.frombuffer(
            archive, dtype="<i2", count=SAMPLE_COUNT, offset=offset + 8
        ).astype(float)
        channels.append(scale * samples - zero)
    return np.mean(channels, axis=0)


def generate_preset(
    name: str,
    raw: np.ndarray,
    target: FrequencyResponse,
    output: Path,
) -> None:
    response = FrequencyResponse(
        name=name,
        frequency=np.geomspace(20, 20_000, SAMPLE_COUNT),
        raw=raw,
    )
    # The downloaded compensation already contains the complete Harman target,
    # so disable AutoEq's optional extra bass/treble shelves.
    response.process(
        compensation=target,
        max_gain=12,
        bass_boost_gain=0,
        bass_boost_fc=105,
        bass_boost_q=0.7,
        treble_boost_gain=0,
        treble_boost_fc=10_000,
        treble_boost_q=0.7,
    )
    peqs = response.optimize_parametric_eq(
        [PEQ_CONFIGS["8_PEAKING_WITH_SHELVES"]],
        fs=48_000,
        max_time=2.0,
    )
    response.write_eqapo_parametric_eq(str(output), peqs)
    text = output.read_text()
    if "Preamp:" not in text or text.count("Filter ") < 4:
        output.unlink(missing_ok=True)
        raise RuntimeError(f"AutoEq produced an invalid preset for {name}")


def main() -> None:
    catalog = json.loads(CATALOG_PATH.read_text())
    missing = [g for g in catalog["graphs"] if not g.get("hasEQ") or not g.get("file")]
    if not missing:
        UNMAPPED_PATH.write_text("")
        print(f"Nothing to fill: {catalog['withEQ']}/{len(catalog['graphs'])} already offline")
        return

    print(f"Fetching PEQdB index and graph archive for {len(missing)} missing models...")
    index, archive, archive_url = load_upstream()
    lookup = build_lookup(index)
    absent = [g["name"] for g in missing if g["name"] not in lookup]
    if absent:
        raise RuntimeError(f"{len(absent)} catalog names missing upstream: {absent[:10]}")

    AUTOEQ_DIR.mkdir(parents=True, exist_ok=True)
    filled = 0
    with tempfile.TemporaryDirectory(prefix="eq-for-mac-peqdb-") as tmp:
        tmpdir = Path(tmp)
        ie_target_path = tmpdir / "harman_ie.csv"
        oe_target_path = tmpdir / "harman_oe.csv"
        ie_target_path.write_bytes(download(IE_TARGET_URL))
        oe_target_path.write_bytes(download(OE_TARGET_URL))
        targets = {
            "IE": FrequencyResponse.read_from_csv(str(ie_target_path)),
            "OE": FrequencyResponse.read_from_csv(str(oe_target_path)),
        }

        for position, graph in enumerate(missing, 1):
            name = graph["name"]
            # Index order is PEQdB's source preference. The first variant is the
            # source's primary/default measurement; average its L/R samples.
            kind, source, variants = lookup[name][0]
            variant, record_range = next(iter(variants.items()))
            start, count = record_range
            raw = decode_graph(archive, start, count)

            digest = hashlib.sha1(
                f"peqdb-archive:{kind}:{source}:{name}:{variant}".encode()
            ).hexdigest()[:12]
            filename = f"{digest}.txt"
            output = AUTOEQ_DIR / filename
            if not output.exists():
                generate_preset(name, raw, targets[kind], output)

            graph.update(
                hasEQ=True,
                file=filename,
                source=f"PEQdB/{source}",
                autoeqName=name,
                path=f"generated/peqdb/{kind}/{source}/{variant or 'default'}",
            )
            filled += 1
            if position % 50 == 0 or position == len(missing):
                print(f"  generated {position}/{len(missing)}")

    catalog["withEQ"] = sum(bool(g.get("hasEQ") and g.get("file")) for g in catalog["graphs"])
    catalog["mode"] = "offline"
    catalog["source"] = (
        "PEQdB names + AutoEq bundled + Squiglink and PEQdB public FR archives→Harman PEQ"
    )
    catalog["peqdbArchiveFilled"] = filled
    catalog["peqdbArchiveURL"] = archive_url
    catalog["peqdbArchiveSHA256"] = hashlib.sha256(archive).hexdigest()
    CATALOG_PATH.write_text(json.dumps(catalog, separators=(",", ":")))

    still_missing = [g["name"] for g in catalog["graphs"] if not g.get("hasEQ") or not g.get("file")]
    UNMAPPED_PATH.write_text("\n".join(still_missing) + ("\n" if still_missing else ""))
    print(
        f"Done: filled={filled}, offline={catalog['withEQ']}/{len(catalog['graphs'])}, "
        f"unmapped={len(still_missing)}"
    )


if __name__ == "__main__":
    main()
