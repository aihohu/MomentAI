"""Exercise publication boundaries with isolated synthetic repositories and archives."""

import io
import json
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

from test_preparation import load

docs = load("check_documentation")


class DocumentationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        (self.root / "docs").mkdir()
        (self.root / ".gitignore").write_text(
            "".join(f"/{name}/\n" for name in sorted(docs.PROCESS_DIRS))
        )
        (self.root / ".gitattributes").write_text(
            "".join(f"{name} export-ignore\n" for name in sorted(docs.PROCESS_DIRS))
        )
        (self.root / "pubspec.yaml").write_text(
            "version: 1.0.0+1\nflutter:\n  assets:\n    - assets/legal/\n"
        )
        self.entries = []
        for suffix, language, other in (("", "en", ".zh-CN"), (".zh-CN", "zh-CN", "")):
            name = f"docs/README{suffix}.md"
            translation = f"docs/README{other}.md"
            (self.root / name).write_text(f"# Guide\n\n`1.0.0+1` [Language](README{other}.md)\n")
            self.entries.append(
                {"path": name, "language": language, "audience": "all", "translation": translation}
            )
        self.save_manifest()

    def save_manifest(self):
        (self.root / "docs/manifest.json").write_text(
            json.dumps({"schemaVersion": 1, "documents": self.entries})
        )

    def test_curated_pair_passes_but_unlisted_report_does_not(self):
        docs.check(self.root)
        (self.root / "docs/acceptance.md").write_text("# Temporary report\n")
        with self.assertRaisesRegex(SystemExit, "Unlisted public prose"):
            docs.check(self.root)

    def test_unlisted_attachment_and_orphan_page_are_rejected(self):
        (self.root / "docs/raw-report.json").write_text("{}")
        name = "docs/orphan.md"
        (self.root / name).write_text("# Unlinked guide\n")
        self.entries.append(
            {"path": name, "audience": "developers", "language": "en", "singleLanguage": True}
        )
        self.save_manifest()
        with self.assertRaises(SystemExit) as failure:
            docs.check(self.root)
        self.assertIn("Unlisted documentation asset", str(failure.exception))
        self.assertIn("Document missing from navigation", str(failure.exception))

    def test_existing_ignored_target_and_missing_anchor_are_rejected(self):
        private = self.root / ".local/report.md"
        private.parent.mkdir()
        private.write_text("# Private\n")
        with (self.root / "docs/README.md").open("a") as stream:
            stream.write("\n[Local](../.local/report.md) [Bad](README.zh-CN.md#absent)\n")
        with self.assertRaises(SystemExit) as failure:
            docs.check(self.root)
        self.assertIn("Private link", str(failure.exception))
        self.assertIn("Missing anchor", str(failure.exception))

    def test_asymmetric_translation_and_stale_version_fail(self):
        self.entries[1]["translation"] = "docs/missing.md"
        self.save_manifest()
        (self.root / "pubspec.yaml").write_text("version: 2.0.0+2\n")
        with self.assertRaises(SystemExit) as failure:
            docs.check(self.root)
        self.assertIn("Non-reciprocal", str(failure.exception))
        self.assertIn("version differs", str(failure.exception))

    def test_asset_scope_and_archive_attribute_are_independent_of_ignore(self):
        (self.root / "pubspec.yaml").write_text(
            "version: 1.0.0+1\nflutter:\n  assets:\n    - .local/\n"
        )
        (self.root / ".gitattributes").write_text("")
        with self.assertRaises(SystemExit) as failure:
            docs.check(self.root)
        self.assertIn("Unreviewed Flutter asset scope", str(failure.exception))
        self.assertIn("Source archive does not exclude", str(failure.exception))

    def test_reference_links_unicode_and_duplicate_heading_anchors(self):
        body = (
            "# 中文标题\n# Same\n# Same\n[reference]: README.md#same-1\n```sh\n# not-heading\n```\n"
        )
        self.assertEqual(docs.anchors(body), {"中文标题", "same", "same-1"})
        self.assertEqual(docs.link_targets(body), ["README.md#same-1"])

    def test_tar_and_apk_reject_nested_process_material(self):
        tar = self.root / "source.tar"
        with tarfile.open(tar, "w") as archive:
            entry = tarfile.TarInfo("project/.local/report.txt")
            entry.size = 4
            archive.addfile(entry, io.BytesIO(b"test"))
        with self.assertRaisesRegex(SystemExit, "Process material"):
            docs.check_archive(tar)
        apk = self.root / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("assets/flutter_assets/.local/report.txt", "test")
        with self.assertRaisesRegex(SystemExit, "Process material"):
            docs.check_archive(apk)
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("assets/flutter_assets/assets/legal/notices.json", "[]")
        docs.check_archive(apk)

    def test_packaged_signing_secrets_fail_but_required_public_signatures_pass(self):
        for name in (
            "assets/release.jks",
            "assets/android-signing.properties",
            "assets/AuthKey.p8",
        ):
            with self.subTest(name=name):
                archive = self.root / "app.apk"
                with zipfile.ZipFile(archive, "w") as result:
                    result.writestr(name, "synthetic")
                with self.assertRaisesRegex(SystemExit, "signing credentials"):
                    docs.check_archive(archive)
        ipa = self.root / "app.ipa"
        with zipfile.ZipFile(ipa, "w") as result:
            result.writestr("Payload/Runner.app/embedded.mobileprovision", "public profile")
            result.writestr("Payload/Runner.app/_CodeSignature/CodeResources", "public signature")
        docs.check_archive(ipa)
        with zipfile.ZipFile(ipa, "a") as result:
            result.writestr("Payload/Runner.app/assets/extra.mobileprovision", "unexpected profile")
        with self.assertRaisesRegex(SystemExit, "signing credentials"):
            docs.check_archive(ipa)

    def test_git_archive_excludes_force_added_local_material(self):
        private = self.root / ".local/evidence.txt"
        private.parent.mkdir()
        private.write_text("synthetic evidence")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "add", "-f", ".local/evidence.txt"], cwd=self.root, check=True)
        tree = subprocess.check_output(["git", "write-tree"], cwd=self.root, text=True).strip()
        archive = self.root / "candidate.tar"
        subprocess.run(["git", "archive", tree, "-o", str(archive)], cwd=self.root, check=True)
        docs.check_archive(archive)
        with tarfile.open(archive) as result:
            self.assertIn("docs/README.md", result.getnames())
            self.assertNotIn(".local/evidence.txt", result.getnames())


if __name__ == "__main__":
    unittest.main()
