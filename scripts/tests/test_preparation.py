"""Public preparation regressions using temporary synthetic assets."""

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def load(name):
    path = Path(__file__).resolve().parents[1] / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


models = load("prepare_models")
repository = load("check_repository")
tools = load("setup_native_tools")


class ToolPreparationTest(unittest.TestCase):
    def test_unverified_download_never_replaces_a_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "tool.jar"
            target.write_bytes(b"existing")

            def download(command, **kwargs):
                Path(command[-1]).write_bytes(b"corrupt")

            with patch.object(tools.subprocess, "run", side_effect=download):
                with self.assertRaisesRegex(ValueError, "Checksum mismatch"):
                    tools.download("https://example.test/tool", target, "0" * 64)
            self.assertEqual(target.read_bytes(), b"existing")
            self.assertFalse(target.with_suffix(".part").exists())

    def test_official_distribution_uses_the_wrapper_cache_location(self):
        self.assertEqual(
            tools.wrapper_cache_key(
                "https://services.gradle.org/distributions/gradle-9.3.1-bin.zip"
            ),
            "23ovyewtku6u96viwx3xl3oks",
        )


class ModelPreparationTest(unittest.TestCase):
    def test_invalid_replacement_preserves_existing_asset_and_removes_partial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "models").mkdir()
            source = root / "input"
            source.mkdir()
            (source / "model.bin").write_bytes(b"bad")
            target = root / "assets/test/model.bin"
            target.parent.mkdir(parents=True)
            target.write_bytes(b"old")
            manifest = {
                "id": "test",
                "base_url": "https://example.test/",
                "files": [
                    {"name": "model.bin", "bytes": 4, "sha256": hashlib.sha256(b"good").hexdigest()}
                ],
            }
            (root / "models/bundled.json").write_text(json.dumps(manifest))
            with patch.object(models, "ROOT", root):
                with self.assertRaises(ValueError):
                    models.prepare(source)
                self.assertEqual(target.read_bytes(), b"old")
                self.assertFalse(target.with_name("model.bin.part").exists())
                (source / "model.bin").write_bytes(b"good")
                models.prepare(source)
                with patch.object(
                    models.urllib.request,
                    "urlopen",
                    side_effect=AssertionError("No network expected"),
                ):
                    models.prepare(verify_only=True)


class DeveloperCommandTest(unittest.TestCase):
    def test_native_test_request_does_not_silently_run_shared_tests(self):
        script = Path(__file__).resolve().parents[1] / "dev.py"
        for platform in ("android", "ios"):
            with self.subTest(platform=platform):
                result = subprocess.run(
                    [sys.executable, str(script), "test", "--platform", platform],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("CONTRIBUTING.md", result.stderr)
                self.assertNotIn("+ flutter", result.stdout)


class RepositoryHygieneTest(unittest.TestCase):
    def test_force_added_project_document_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / ".gitignore").write_text("*.md\n")
            project_document = root / "ANDROID_REFINEMENT_30MIN.md"
            project_document.write_text("# Local recording acceptance\n")
            subprocess.run(["git", "-C", str(root), "add", "-f", str(project_document)], check=True)
            with patch.object(repository, "ROOT", root):
                with self.assertRaisesRegex(SystemExit, "Unlisted public documentation"):
                    repository.check()

    def test_force_added_local_report_is_rejected(self):
        for area in (".local", "artifacts"):
            with self.subTest(area=area), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                subprocess.run(["git", "init", "--quiet", str(root)], check=True)
                (root / ".gitignore").write_text(f"/{area}/\n")
                report = root / area / "device-acceptance.json"
                report.parent.mkdir()
                report.write_text("{}\n")
                subprocess.run(["git", "-C", str(root), "add", "-f", str(report)], check=True)
                with patch.object(repository, "ROOT", root):
                    with self.assertRaisesRegex(SystemExit, "device-acceptance.json"):
                        repository.check()

    def test_private_key_content_is_rejected_without_echoing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            marker = "-----BEGIN " + "PRIVATE KEY-----"
            (root / "innocent.txt").write_text(marker + "\nsynthetic-sensitive-content\n")
            with patch.object(repository, "ROOT", root):
                with self.assertRaises(SystemExit) as failure:
                    repository.check()
            self.assertIn("Private key content", str(failure.exception))
            self.assertNotIn("synthetic-sensitive-content", str(failure.exception))

    def test_private_artifacts_are_rejected_without_banning_synthetic_archives(self):
        for name in (
            "data/session.sqlite3",
            ".env.production",
            "android/key.properties",
            "release.apk",
            "AuthKey.p8",
            "nested/signing.PFX",
            "identity.keychain-db",
            "certificate.pem",
            "android-signing.properties",
            "ANDROID-SIGNING-BACKUP.md",
            "android-filing-public.json",
            "local/release-plan.md",
            "validation/clean-build.json",
        ):
            with self.subTest(name=name):
                self.assertTrue(repository.private_artifact(name))
        for name in (".env.example", "test/fixtures/synthetic.momentai", "LICENSE"):
            with self.subTest(name=name):
                self.assertFalse(repository.private_artifact(name))


class CommitSubjectTest(unittest.TestCase):
    def test_commit_body_and_attribution_are_rejected(self):
        self.assertTrue(repository.check_subject("feat(recording): add pause and resume"))
        self.assertFalse(
            repository.check_subject("feat(recording): add pause\n\nCo-authored-by: example")
        )
        self.assertFalse(repository.check_subject("更新项目"))


if __name__ == "__main__":
    unittest.main()
