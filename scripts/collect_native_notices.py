"""Synchronize reviewed native notices into the offline license bundle."""

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def collect(check=False):
    bundle_path = ROOT / "assets/legal/notices.json"
    bundle = json.loads(bundle_path.read_text())
    original = dict(bundle)
    inventory = json.loads((ROOT / "third_party/native/runtime/inventory.json").read_text())
    for component in inventory:
        text = f"{component['name']} {component['version']}\n"
        if "sourceUrl" in component:
            text += f"Source: {component['sourceUrl']}\n"
        else:
            text += (
                "Complete upstream notice set; not all listed components are linked "
                "on every platform.\n"
            )
        notices = []
        for notice in component["notices"]:
            data = (ROOT / notice["path"]).read_bytes()
            if hashlib.sha256(data).hexdigest() != notice["sha256"]:
                raise ValueError(f"Notice hash mismatch: {notice['path']}")
            notices.append(data.decode())
        bundle["Native: " + component["name"]] = text + "\n" + "\n\n".join(notices)
    dependencies = json.loads((ROOT / "third_party/native/android-dependencies.json").read_text())
    coordinates = "\n".join(item["coordinate"] for item in dependencies["dependencies"])
    artifacts = json.loads((ROOT / "third_party/native/android-artifact-notices.json").read_text())
    embedded = []
    for artifact in artifacts:
        for notice in artifact["notices"]:
            data = (ROOT / notice["path"]).read_bytes()
            if hashlib.sha256(data).hexdigest() != notice["sha256"]:
                raise ValueError(f"Artifact notice hash mismatch: {notice['path']}")
            embedded.append(data.decode())
    bundle["Native: Android dependencies"] = (
        "Resolved Android compile/runtime components; some are compile-only.\n"
        "Apache-2.0 applies to AndroidX, Kotlin, and the listed Google libraries.\n"
        "Flutter engine terms and its transitive notices are included separately "
        "by Flutter in this license viewer.\n\n"
        + coordinates
        + "\n\n"
        + (ROOT / "LICENSE").read_text()
        + "\n\n"
        + "\n\n".join(embedded)
    )
    if check:
        if bundle != original:
            raise ValueError("Run python3 scripts/collect_native_notices.py")
    else:
        bundle_path.write_text(json.dumps(bundle, indent=2, ensure_ascii=False) + "\n")
    print("Native offline notices verified" if check else "Native offline notices updated")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    collect(parser.parse_args().check)
