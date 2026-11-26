"""Collect resolved Dart dependency notices without copying source or model weights."""

import hashlib
import json
import re
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]


def main():
    config_path = ROOT / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text())
    destination = ROOT / "third_party/dart"
    destination.mkdir(parents=True, exist_ok=True)
    packages = []
    components = []
    for package in sorted(config["packages"], key=lambda item: item["name"]):
        name = package["name"]
        if name == "momentai":
            continue
        uri = urlparse(package["rootUri"])
        source = (
            Path(unquote(uri.path))
            if uri.scheme == "file"
            else config_path.parent / unquote(uri.path)
        )
        pubspec = (source / "pubspec.yaml").read_text()
        match = re.search(r"^version:\s*[\"']?([^\s\"']+)", pubspec, re.MULTILINE)
        version = match.group(1) if match else "sdk"
        notices = [
            path
            for path in source.iterdir()
            if path.is_file() and path.name.upper().startswith(("LICENSE", "NOTICE", "COPYING"))
        ]
        if not notices and source.parent.name == "packages":
            sdk_license = source.parent.parent / "LICENSE"
            if sdk_license.is_file():
                notices = [sdk_license]
        if not notices:
            raise ValueError(f"No license text found for resolved dependency {name}")
        records = []
        for path in sorted(notices):
            output = destination / name / path.name
            output.parent.mkdir(parents=True, exist_ok=True)
            content = path.read_bytes()
            output.write_bytes(content)
            records.append(
                {
                    "path": output.relative_to(ROOT).as_posix(),
                    "sha256": hashlib.sha256(content).hexdigest(),
                }
            )
        packages.append({"name": name, "version": version, "notices": records})
        components.append(
            {
                "type": "library",
                "name": name,
                "version": version,
                "purl": (
                    f"pkg:generic/momentai/{name}@{version}"
                    if source.resolve().is_relative_to(ROOT / "packages")
                    else f"pkg:pub/{name}@{version}"
                ),
                "licenses": [
                    {
                        "license": {
                            "name": "See bundled dependency license",
                            "url": records[0]["path"],
                        }
                    }
                ],
            }
        )
    (ROOT / "third_party/dart-inventory.json").write_text(json.dumps(packages, indent=2) + "\n")
    (ROOT / "third_party/dart-sbom.cdx.json").write_text(
        json.dumps(
            {
                "bomFormat": "CycloneDX",
                "specVersion": "1.6",
                "version": 1,
                "metadata": {
                    "component": {
                        "type": "application",
                        "name": "MomentAI Dart dependency inventory",
                    }
                },
                "components": components,
            },
            indent=2,
        )
        + "\n"
    )
    print(f"Collected notices for {len(packages)} resolved Dart packages (including tooling)")


if __name__ == "__main__":
    main()
