#!/usr/bin/env python3
"""Builds the cloud-init NoCloud seed ISO the in-app VM boots with.

    pip install pycdlib
    python3 Scripts/make-seed-iso.py

Reads Guest/cloud-init/{user-data,meta-data} and writes
Sources/LinuxVM/Resources/seed.iso (volume label "cidata", Joliet + Rock
Ridge so cloud-init sees the lowercase, hyphenated file names). Same layout
`cloud-localds` produces; pure Python so it runs on the Windows/Linux/macOS
machines this repo is edited on without genisoimage/xorriso.
"""
import io
import pathlib

import pycdlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Guest" / "cloud-init"
OUT = ROOT / "Sources" / "LinuxVM" / "Resources" / "seed.iso"


def main() -> None:
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="cidata")
    for index, name in enumerate(["user-data", "meta-data"]):
        data = (SRC / name).read_bytes()
        iso.add_fp(
            io.BytesIO(data),
            len(data),
            f"/FILE{index}.;1",
            rr_name=name,
            joliet_path=f"/{name}",
        )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    iso.write(str(OUT))
    iso.close()
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
