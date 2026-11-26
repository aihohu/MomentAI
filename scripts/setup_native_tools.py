"""Download pinned developer tools, with an explicit checksum-verified mirror option."""

import argparse
import hashlib
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.7.1"
SHA256 = "5f3de4ee4014137b05c72ed68eb46fe686aeb11fbdef27faf77f55d51c1b2536"
URL = f"https://repo.maven.apache.org/maven2/com/pinterest/ktlint/ktlint-cli/{VERSION}/ktlint-cli-{VERSION}-all.jar"
MIRROR = "https://repo.huaweicloud.com"


def digest(path):
    if not path.exists():
        return None
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(url, path, checksum):
    if digest(path) == checksum:
        print(f"Already verified: {path.name}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(".part")
    try:
        subprocess.run(
            [
                "curl",
                "--fail",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--max-time",
                "1800",
                "--connect-timeout",
                "15",
                "--retry",
                "2",
                "--speed-limit",
                "1024",
                "--speed-time",
                "60",
                url,
                "--output",
                str(partial),
            ],
            check=True,
        )
        if digest(partial) != checksum:
            raise ValueError(f"Checksum mismatch: {path.name}")
        partial.replace(path)
        print(f"Downloaded and verified: {path.name}")
    finally:
        partial.unlink(missing_ok=True)


def wrapper_cache_key(url):
    """Match Gradle PathAssembler's URL hash; this is a cache key, not integrity."""
    value = int.from_bytes(hashlib.md5(url.encode(), usedforsecurity=False).digest(), "big")
    result = ""
    while value:
        value, digit = divmod(value, 36)
        result = "0123456789abcdefghijklmnopqrstuvwxyz"[digit] + result
    return result or "0"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mirror", choices=["huaweicloud"], help="Opt-in public download mirror")
    parser.add_argument("--gradle", action="store_true", help="Also prepare the pinned wrapper ZIP")
    args = parser.parse_args()
    url = URL.replace("https://repo.maven.apache.org/maven2", f"{MIRROR}/repository/maven")
    download(url if args.mirror else URL, ROOT / ".tools/ktlint", SHA256)
    if args.gradle:
        properties = dict(
            line.split("=", 1)
            for line in (ROOT / "android/gradle/wrapper/gradle-wrapper.properties")
            .read_text()
            .splitlines()
            if "=" in line and not line.startswith("#")
        )
        official = properties["distributionUrl"].replace("\\:", ":")
        filename = official.rsplit("/", 1)[1]
        home = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")).expanduser()
        target = home / "wrapper/dists" / filename.removesuffix(".zip")
        target = target / wrapper_cache_key(official) / filename
        download(
            f"{MIRROR}/gradle/{filename}" if args.mirror else official,
            target,
            properties["distributionSha256Sum"],
        )


if __name__ == "__main__":
    main()
