#!/usr/bin/env python3
"""Check arm64 ELF PT_LOAD alignment and stored .so offsets in an APK.

This is a static check, not evidence of execution on a 16 KB Android system.
Usage: python3 scripts/check_android_native_alignment.py <arm64-lib-dir-or-apk>
"""

import argparse
import hashlib
import json
import struct
import sys
import zipfile
from pathlib import Path


def read_exact(stream, size):
    result = stream.read(size)
    if len(result) != size:
        raise ValueError("Truncated ELF/ZIP header")
    return result


def elf_alignment(stream):
    header = read_exact(stream, 64)
    if header[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected little-endian ELF64")
    if struct.unpack_from("<H", header, 18)[0] != 183:
        raise ValueError("Expected AArch64 ELF")
    offset = struct.unpack_from("<Q", header, 32)[0]
    entry_size, count = struct.unpack_from("<HH", header, 54)
    if entry_size != 56 or count == 0 or count > 1024:
        raise ValueError("Invalid ELF program header table")
    segments = []
    for index in range(count):
        stream.seek(offset + index * entry_size)
        program = read_exact(stream, entry_size)
        if struct.unpack_from("<I", program)[0] != 1:
            continue
        file_offset, virtual_address = struct.unpack_from("<QQ", program, 8)
        alignment = struct.unpack_from("<Q", program, 48)[0]
        segments.append(
            {
                "alignment": alignment,
                "pass": alignment >= 16384
                and alignment & (alignment - 1) == 0
                and (file_offset - virtual_address) % 16384 == 0,
            }
        )
    return {"segments": segments, "pass": bool(segments) and all(s["pass"] for s in segments)}


def inspect(path):
    libraries = []
    if path.is_dir():
        for library in sorted(path.glob("*.so")):
            with library.open("rb") as stream:
                record = elf_alignment(stream)
            with library.open("rb") as stream:
                record["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
            libraries.append({"name": library.name, **record})
    else:
        with zipfile.ZipFile(path) as archive, path.open("rb") as raw:
            for entry in archive.infolist():
                if not entry.filename.startswith("lib/arm64-v8a/") or not entry.filename.endswith(
                    ".so"
                ):
                    continue
                with archive.open(entry) as stream:
                    record = elf_alignment(stream)
                with archive.open(entry) as stream:
                    record["sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
                raw.seek(entry.header_offset)
                header = read_exact(raw, 30)
                if header[:4] != b"PK\x03\x04":
                    raise ValueError("Invalid ZIP local header")
                name_size, extra_size = struct.unpack_from("<HH", header, 26)
                data_offset = entry.header_offset + 30 + name_size + extra_size
                stored = entry.compress_type == zipfile.ZIP_STORED
                record["zipStored"] = stored
                record["zipDataOffset"] = data_offset
                record["zipAlignmentPass"] = not stored or data_offset % 16384 == 0
                record["pass"] = record["pass"] and record["zipAlignmentPass"]
                libraries.append({"name": entry.filename, **record})
    return {
        "schemaVersion": 1,
        "input": str(path),
        "scope": "static arm64 check only",
        "pass": bool(libraries) and all(item["pass"] for item in libraries),
        "libraries": libraries,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    args = parser.parse_args()
    try:
        result = inspect(args.input)
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
        result = {"pass": False, "error": str(error)}
    print(json.dumps(result, indent=2))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
