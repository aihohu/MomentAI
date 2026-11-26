"""Consistent local and CI checks. No command installs or starts a phone app."""

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*command):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["format", "check", "test"])
    parser.add_argument("--platform", choices=["shared", "android", "ios"], default="shared")
    args = parser.parse_args()
    if args.command == "test" and args.platform != "shared":
        parser.error(
            "Native test commands are explicit in CONTRIBUTING.md; use test --platform shared"
        )
    flutter = os.environ.get("FLUTTER", "flutter")
    dart = os.environ.get("DART", "dart")
    ruff = ROOT / ".venv/bin/ruff"
    ruff_command = str(ruff) if ruff.exists() else "ruff"
    if args.command == "test":
        run(flutter, "test", "--no-pub")
        run(sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests")
        return
    formatting = args.command == "format"
    if args.platform == "shared":
        run(
            dart,
            "format",
            *([] if formatting else ["--output=none", "--set-exit-if-changed"]),
            "lib",
            "test",
        )
        run(ruff_command, "check", *(["--fix"] if formatting else []), "scripts", ".githooks")
        run(ruff_command, "format", *([] if formatting else ["--check"]), "scripts", ".githooks")
        run("npm", "run", "format:docs" if formatting else "lint:docs")
        if not formatting:
            run(flutter, "analyze", "--no-pub", "--fatal-infos")
            run(sys.executable, "scripts/check_localizations.py")
            run(sys.executable, "scripts/collect_native_notices.py", "--check")
            run(sys.executable, "scripts/check_repository.py")
            run(sys.executable, "scripts/check_documentation.py")
    elif args.platform == "android":
        run(
            "java",
            "-jar",
            ROOT / ".tools/ktlint",
            *(["--format"] if formatting else []),
            "android/**/*.kt",
            "android/**/*.kts",
            "packages/**/*.kts",
        )
    else:
        if platform.system() != "Darwin":
            raise SystemExit("iOS checks require macOS and Xcode; no checks were run")
        run(
            "xcrun",
            "swift-format",
            "format" if formatting else "lint",
            "--recursive",
            *(["--in-place"] if formatting else ["--strict"]),
            "ios/Runner",
            "ios/RunnerTests",
            "packages/sherpa_onnx_ios/ios/sherpa_onnx_ios/Package.swift",
            "packages/sherpa_onnx_ios/ios/sherpa_onnx_ios/Sources",
        )


if __name__ == "__main__":
    main()
