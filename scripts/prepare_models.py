"""Prepare verified build assets without storing model weights in Git."""

import argparse
import hashlib
import json
import shutil
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def valid(path, item):
    if not path.is_file() or path.stat().st_size != item["bytes"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == item["sha256"]


def prepare(source=None, verify_only=False):
    manifest = json.loads((ROOT / "models/bundled.json").read_text())
    destination = ROOT / "assets" / manifest["id"]
    destination.mkdir(parents=True, exist_ok=True)
    for item in manifest["files"]:
        name = item["name"]
        if Path(name).name != name:
            raise ValueError("Model filenames must be single path components")
        target = destination / name
        if valid(target, item):
            print(f"Verified {name}")
            continue
        if verify_only:
            raise ValueError(f"Missing or invalid model asset: {name}")
        partial = target.with_name(target.name + ".part")
        try:
            if source:
                shutil.copyfile(source / name, partial)
            else:
                request = urllib.request.Request(
                    manifest["base_url"] + name, headers={"User-Agent": "MomentAI-Build/1"}
                )
                with urllib.request.urlopen(request, timeout=60) as response:
                    if not response.url.startswith("https://"):
                        raise ValueError("Model download redirected outside HTTPS")
                    with partial.open("wb") as output:
                        received = 0
                        while chunk := response.read(1024 * 1024):
                            received += len(chunk)
                            if received > item["bytes"]:
                                raise ValueError(f"Oversized model asset: {name}")
                            output.write(chunk)
            if not valid(partial, item):
                raise ValueError(f"Model size or SHA-256 mismatch: {name}")
            partial.replace(target)
            print(f"Prepared {name}")
        finally:
            partial.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-directory", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    arguments = parser.parse_args()
    prepare(arguments.from_directory, arguments.verify_only)
