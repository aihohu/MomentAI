"""Validate curated prose, local links, packaging scope and exported archive paths."""

import argparse
import json
import re
import subprocess
import tarfile
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

try:
    from .check_repository import signing_material
except ImportError:
    from check_repository import signing_material

ROOT = Path(__file__).resolve().parents[1]
PROCESS_DIRS = {".local", "artifacts", "local", "validation", ".derived-data"}


def source_files(root):
    return set(
        subprocess.check_output(
            ["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=root, text=True
        ).split("\0")
    ) - {""}


def prose(text):
    return re.sub(r"^\s*(`{3,}|~{3,}).*?^\s*\1\s*$", "", text, flags=re.M | re.S)


def anchors(text):
    found = set(re.findall(r"\bid=[\"\']([^\"\']+)[\"\']", prose(text)))
    counts = {}
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*#*\s*$", prose(text), re.M):
        heading = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", heading)
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        found.add(f"{slug}-{count}" if count else slug)
    return found


def link_targets(text):
    text = prose(text)
    # Reviewed prose uses inline links or reference definitions, without nested URLs.
    return re.findall(r"\[[^\]]*\]\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)", text) + re.findall(
        r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)", text, re.M
    )


def check_link(root, name, target, files, public):
    target = target.strip("<>")
    url = urlsplit(target)
    if url.scheme or url.netloc:
        return None
    destination = (root / name).parent / unquote(url.path) if url.path else root / name
    resolved = destination.resolve()
    if not resolved.is_relative_to(root.resolve()):
        return f"Link escapes repository in {name}: {target}"
    relative = resolved.relative_to(root.resolve()).as_posix()
    if any(part in PROCESS_DIRS for part in Path(relative).parts):
        return f"Private link in {name}: {target}"
    if destination.is_dir():
        visible = any(file.startswith(relative + "/") for file in files)
    else:
        visible = relative in files and destination.is_file()
    if not visible:
        return f"Missing or unpublished link in {name}: {target}"
    if destination.suffix.lower() == ".md":
        if relative not in public and not relative.startswith("third_party/"):
            return f"Unlisted prose link in {name}: {target}"
        if url.fragment and unquote(url.fragment) not in anchors(destination.read_text()):
            return f"Missing anchor in {name}: {target}"
    return None


def check(root=ROOT):
    files = source_files(root)
    manifest = json.loads((root / "docs/manifest.json").read_text())
    errors = []
    if manifest.get("schemaVersion") != 1:
        errors.append("Unsupported documentation manifest schema")
    entries = manifest["documents"]
    public = {item["path"] for item in entries}
    by_path = {item["path"]: item for item in entries}
    navigation = {}
    if len(entries) != len(public):
        errors.append("Duplicate documentation manifest entry")
    for item in entries:
        name = item["path"]
        path = root / name
        if (
            Path(name).is_absolute()
            or ".." in Path(name).parts
            or any(part in PROCESS_DIRS for part in Path(name).parts)
            or not path.resolve().is_relative_to(root.resolve())
            or name not in files
            or not path.is_file()
            or path.suffix != ".md"
        ):
            errors.append(f"Missing or private manifest document: {name}")
            continue
        if item.get("audience") not in {
            "all",
            "users",
            "developers",
            "contributors",
            "maintainers",
        }:
            errors.append(f"Missing/invalid audience: {name}")
        if item.get("language") not in {"en", "zh-CN"}:
            errors.append(f"Missing/invalid language: {name}")
        body = path.read_text()
        targets = link_targets(body)
        navigation[name] = set()
        for target in targets:
            url = urlsplit(target.strip("<>"))
            if not url.scheme and not url.netloc:
                linked = (path.parent / unquote(url.path)).resolve() if url.path else path.resolve()
                if linked.is_relative_to(root.resolve()):
                    navigation[name].add(linked.relative_to(root.resolve()).as_posix())
        translation = item.get("translation")
        if translation:
            other = by_path.get(translation, {})
            if (
                other.get("translation") != name
                or other.get("language") == item.get("language")
                or other.get("audience") != item.get("audience")
            ):
                errors.append(f"Non-reciprocal language pair: {name}")
            if not any(
                (path.parent / t).resolve() == (root / translation).resolve() for t in targets
            ):
                errors.append(f"Missing language switch: {name}")
        elif item.get("singleLanguage") is not True:
            errors.append(f"Missing language policy: {name}")
        if re.search(r"/(?:Users|home)/[\w.-]+/|[A-Z]:\\Users\\", body):
            errors.append(f"Workstation path in public prose: {name}")
        for target in targets:
            error = check_link(root, name, target, files, public)
            if error:
                errors.append(error)
    reachable = set()
    pending = [
        name
        for name in public
        if name in {"README.md", "README.zh-CN.md", "docs/README.md", "docs/README.zh-CN.md"}
    ]
    while pending:
        current = pending.pop()
        if current in reachable:
            continue
        reachable.add(current)
        pending.extend(navigation.get(current, set()) & public)
    for name in public - reachable:
        if name.startswith("docs/"):
            errors.append(f"Document missing from navigation: {name}")
    for name in files:
        if name.startswith("docs/") and name not in public | {"docs/manifest.json"}:
            errors.append(f"Unlisted documentation asset: {name}")
        path = Path(name)
        if path.suffix.lower() in {".md", ".mdx", ".rst", ".html"} and name not in public:
            upstream = name.startswith("third_party/") and path.name.upper().startswith(
                ("LICENSE", "NOTICE", "COPYING")
            )
            if not upstream:
                errors.append(f"Unlisted public prose: {name}")
    version = re.search(r"^version:\s*(\S+)", (root / "pubspec.yaml").read_text(), re.M)[1]
    for name in ("docs/README.md", "docs/README.zh-CN.md"):
        if f"`{version}`" not in (root / name).read_text():
            errors.append(f"Documentation app version differs from pubspec: {name}")
    # Flutter asset declarations are explicit lists in this repository.
    assets = (root / "pubspec.yaml").read_text().split("  assets:\n", 1)[-1]
    for asset in re.findall(r"^    - (.+)$", assets, re.M):
        if not asset.startswith("assets/") or any(p in PROCESS_DIRS for p in Path(asset).parts):
            errors.append(f"Unreviewed Flutter asset scope: {asset}")
    for directory in sorted(PROCESS_DIRS):
        ignored = subprocess.run(
            ["git", "check-ignore", "--no-index", "-q", f"{directory}/probe"], cwd=root, check=False
        )
        if ignored.returncode != 0:
            errors.append(f"Process directory is not ignored: {directory}")
        attr = subprocess.check_output(
            ["git", "check-attr", "export-ignore", "--", directory], cwd=root, text=True
        )
        if not attr.strip().endswith(": set"):
            errors.append(f"Source archive does not exclude: {directory}")
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Documentation checks passed ({len(public)} public documents)")


def check_archive(path):
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
    else:
        with tarfile.open(path) as archive:
            names = [member.name for member in archive]
    invalid = [
        name
        for name in names
        if any(part in PROCESS_DIRS for part in Path(name.replace("\\", "/")).parts)
        or (
            signing_material(name)
            # Signed iOS distributions can require this public provisioning payload.
            # It is not a private key; never allow it in source TARs or arbitrary assets.
            and not (
                path.suffix.lower() == ".ipa"
                and re.fullmatch(
                    r"Payload/[^/]+\.app/(?:PlugIns/[^/]+\.appex/)?embedded\.mobileprovision", name
                )
            )
        )
    ]
    if invalid:
        raise SystemExit(
            "Process material or signing credentials in archive:\n" + "\n".join(invalid)
        )
    print(f"Archive process-path check passed ({len(names)} entries)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--archive", type=Path, help="Inspect a source TAR or application ZIP/APK/IPA"
    )
    args = parser.parse_args()
    if args.archive:
        check_archive(args.archive)
    else:
        check()
