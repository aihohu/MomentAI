"""Check public source hygiene and commit subjects without reading user data."""

import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUBJECT = re.compile(
    r"^(feat|fix|refactor|test|docs|build|ci|chore|perf|style|revert)"
    r"\([a-z][a-z0-9-]*\): [a-z][\x20-\x7e]+$"
)


def check_subject(message):
    lines = message.strip().splitlines()
    return len(lines) == 1 and len(lines[0]) <= 100 and bool(SUBJECT.fullmatch(lines[0]))


PRIVATE_SUFFIXES = {
    ".onnx",
    ".pcm",
    ".sqlite",
    ".sqlite3",
    ".db",
    ".jks",
    ".keystore",
    ".p12",
    ".p8",
    ".mobileprovision",
    ".apk",
    ".aab",
    ".ipa",
    ".xcresult",
}


def published_markdown(name):
    manifest = ROOT / "docs/manifest.json"
    public = (
        {item["path"] for item in json.loads(manifest.read_text())["documents"]}
        if manifest.exists()
        else set()
    )
    path = Path(name)
    return name in public or (
        name.startswith("third_party/")
        and path.name.upper().startswith(("LICENSE", "NOTICE", "COPYING"))
    )


SIGNING_SUFFIXES = {
    ".jks",
    ".keystore",
    ".p12",
    ".pfx",
    ".p8",
    ".key",
    ".pem",
    ".mobileprovision",
    ".provisionprofile",
    ".keychain",
    ".keychain-db",
}
SIGNING_NAMES = {
    "key.properties",
    "android-signing.properties",
    "id_rsa",
    "id_ed25519",
    "android-signing-backup.md",
    "android-filing-public.json",
}
PRIVATE_KEY_HEADER = re.compile(rb"(?m)^-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----\r?$")


def signing_material(name):
    path = Path(name.replace("\\", "/"))
    return path.suffix.lower() in SIGNING_SUFFIXES or path.name.lower() in SIGNING_NAMES


def private_artifact(name):
    path = Path(name)
    return (
        (
            path.parts
            and path.parts[0] in {".local", "artifacts", "local", "validation", ".derived-data"}
        )
        or path.suffix.lower() in PRIVATE_SUFFIXES
        or signing_material(name)
        or (path.name.startswith(".env") and not path.name.endswith(".example"))
    )


def check():
    result = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    errors = []
    for name in sorted(set(result.stdout.decode().split("\0")) - {""}):
        path = ROOT / name
        if not path.is_file():
            continue
        if path.stat().st_size > 5 * 1024 * 1024:
            errors.append(f"Oversized source file: {name}")
        if private_artifact(name):
            errors.append(f"Private or external asset in source: {name}")
        if path.stat().st_size <= 5 * 1024 * 1024 and PRIVATE_KEY_HEADER.search(path.read_bytes()):
            errors.append(f"Private key content in source: {name}")
        if path.suffix.lower() == ".md":
            if not published_markdown(name):
                errors.append(f"Unlisted public documentation: {name}")
    if errors:
        raise SystemExit("\n".join(errors))
    print("Public repository checks passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subject")
    parser.add_argument("--commits", help="Git revision range to validate")
    args = parser.parse_args()
    if args.subject is not None:
        if not check_subject(args.subject):
            raise SystemExit("Use one English line: type(scope): imperative description")
    elif args.commits:
        messages = subprocess.check_output(
            ["git", "log", "--format=%B%x00", args.commits], cwd=ROOT, text=True
        )
        if any(not check_subject(message) for message in messages.split("\0") if message.strip()):
            raise SystemExit("Commit messages must be single conventional English subjects")
    else:
        check()
