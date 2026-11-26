"""Native input and build audit failures use small synthetic fixtures."""

import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from test_preparation import load

native = load("build_native_runtime")


class NativeRuntimeAuditTest(unittest.TestCase):
    def test_archive_cannot_escape_source_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "input.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../../escaped", "untrusted")
            record = {"directory": "source", "sha256": native.digest(archive)}
            with patch.object(native, "WORK", root):
                with self.assertRaisesRegex(ValueError, "escapes"):
                    native.extract(archive, record)
            self.assertFalse((root / "escaped").exists())

    def test_offline_input_requires_matching_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "downloads").mkdir()
            (root / "downloads/input.zip").write_bytes(b"corrupted")
            with patch.object(native, "WORK", root):
                with self.assertRaisesRegex(ValueError, "Missing verified input"):
                    native.acquire({"file": "input.zip", "sha256": "0" * 64}, offline=True)

    def test_disabled_flag_does_not_hide_forbidden_link_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "CMakeCache.txt").write_text("SHERPA_ONNX_ENABLE_TTS:BOOL=OFF\n")
            (root / "compile_commands.json").write_text(json.dumps([{"file": "asr.cc"}]))
            (root / "link.txt").write_text("c++ asr.o speaker.o")
            (root / "runtime.map").write_text("SherpaOnnxCreateSpeakerEmbeddingExtractor")
            self.assertEqual(native.verify_build(root)["linkRecords"], 1)
            (root / "link.txt").write_text("c++ asr.o libespeak.a")
            with self.assertRaisesRegex(ValueError, "Forbidden TTS link input"):
                native.verify_build(root)


if __name__ == "__main__":
    unittest.main()
