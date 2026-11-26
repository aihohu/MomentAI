#!/usr/bin/env python3
"""Check translation key/placeholder parity using only the Python standard library."""

import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def messages(path):
    data = json.loads(path.read_text())
    return {key: value for key, value in data.items() if not key.startswith("@")}


def placeholders(value):
    return set(re.findall(r"\{(\w+)(?:\}|,)", value))


def compare(reference, localized, path, parameters):
    require(
        reference.keys() == localized.keys(),
        f"{path}: missing/extra keys: {reference.keys() ^ localized.keys()}",
    )
    for key, text in localized.items():
        require(bool(text.strip()), f"{path}: empty message {key}")
        require(
            parameters(text) == parameters(reference[key]), f"{path}: placeholder mismatch in {key}"
        )


def strings_file(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        match = re.fullmatch(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', line)
        require(match is not None, f"{path}: invalid strings entry: {line}")
        key, value = map(json.loads, match.groups())
        require(key not in result, f"{path}: duplicate key {key}")
        result[key] = value
    return result


def android_strings(path):
    result = {}
    for item in ET.parse(path).getroot():
        if item.tag == "string":
            key = item.attrib["name"]
            require(key not in result, f"{path}: duplicate key {key}")
            result[key] = "".join(item.itertext())
    return result


def main():
    reference = messages(ROOT / "lib/l10n/app_zh.arb")
    arbs = sorted((ROOT / "lib/l10n").glob("app_*.arb"))
    for path in arbs:
        compare(reference, messages(path), path, placeholders)

    def native_parameters(value):
        return re.findall(r"%(?:\d+\$)?[sd@]", value)

    android_root = ROOT / "android/app/src/main/res"
    android_base = android_strings(android_root / "values/strings.xml")
    for path in android_root.glob("values-*/strings.xml"):
        compare(android_base, android_strings(path), path, native_parameters)
    for name in ["Localizable.strings", "InfoPlist.strings"]:
        reference_native = strings_file(ROOT / f"ios/Runner/en.lproj/{name}")
        for path in (ROOT / "ios/Runner").glob(f"*.lproj/{name}"):
            compare(reference_native, strings_file(path), path, native_parameters)
    print(
        f"Localization resources valid: {len(arbs)} Flutter languages, {len(reference)} messages; Android and iOS key/placeholder parity passed."
    )


if __name__ == "__main__":
    main()
