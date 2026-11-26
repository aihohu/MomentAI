"""Verify native build evidence, Dart ABI exports, and retained license hashes."""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlparse

from build_native_runtime import ROOT, digest, verify_build


def audit(platform):
    report = json.loads((ROOT / f".local/validation/native/{platform}-build.json").read_text())
    if report["lockSha256"] != digest(ROOT / "native/runtime-lock.json"):
        raise ValueError("Runtime build does not match the current input lock")
    config_path = ROOT / ".dart_tool/package_config.json"
    packages = json.loads(config_path.read_text())["packages"]
    package = next(item for item in packages if item["name"] == "sherpa_onnx")
    uri = urlparse(package["rootUri"])
    source = Path(unquote(uri.path)) if uri.scheme == "file" else config_path.parent / uri.path
    bindings = (source / "lib/src/sherpa_onnx_bindings.dart").read_text()
    required = set(re.findall(r"['\"](SherpaOnnx\w+)['\"]", bindings))
    if not required:
        raise ValueError("No Dart ABI requirements found")
    if platform == "android":
        sdk = Path(os.environ.get("ANDROID_SDK_ROOT", os.environ.get("ANDROID_HOME", "")))
        lock = json.loads((ROOT / "native/runtime-lock.json").read_text())
        ndk = Path(os.environ.get("ANDROID_NDK_HOME", sdk / "ndk" / lock["android"]["ndk"]))
        candidates = list(ndk.glob("toolchains/llvm/prebuilt/*/bin/llvm-nm"))
        nm = [str(candidates[0]), "-D", "--defined-only"]
    else:
        nm = ["nm", "-gU"]
    for name, recorded in report["variants"].items():
        current = verify_build(ROOT / ".tools/native/build" / name)
        if any(recorded.get(key) != value for key, value in current.items()):
            raise ValueError(f"Build records changed after compilation: {name}")
    checked = []
    for relative, record in report["outputs"].items():
        binary = ROOT / relative
        if digest(binary) != record["sha256"]:
            raise ValueError(f"Runtime output changed: {relative}")
        if binary.name == "libonnxruntime.so":
            continue
        symbols = subprocess.check_output([*nm, str(binary)], text=True)
        exported = set(re.findall(r"\b_?(SherpaOnnx\w+)\b", symbols))
        missing = sorted(required - exported)
        if missing:
            raise ValueError(f"Missing Dart ABI exports in {relative}: {missing}")
        checked.append(relative)
    inventory = json.loads((ROOT / "third_party/native/runtime/inventory.json").read_text())
    for component in inventory:
        for notice in component["notices"]:
            if digest(ROOT / notice["path"]) != notice["sha256"]:
                raise ValueError(f"Native notice changed: {notice['path']}")
    result = {
        "platform": platform,
        "requiredDartSymbols": len(required),
        "binaries": checked,
        "noticeComponents": len(inventory),
        "pass": True,
    }
    (ROOT / f".local/validation/native/{platform}-audit.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["android", "ios"], required=True)
    audit(parser.parse_args().platform)
