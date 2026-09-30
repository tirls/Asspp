"""Offline build-script regression tests; no Xcode build or downloads required."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zlib

spec = importlib.util.spec_from_file_location("sap_build", Path(__file__).parents[1] / "Scripts/prepare.sap.py")
sap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sap)


class SAPBuildChecks(unittest.TestCase):
    def test_prefix_reader_preserves_requested_sizes(self):
        reader = sap.PrefixedReader(io.BytesIO(b"payload"))
        self.assertEqual(reader.read(0), b"")
        self.assertEqual(reader.read(2), b"BZ")
        self.assertEqual(reader.read(3), b"h9p")
        self.assertEqual(reader.read(), b"ayload")

    def test_exact_handles_short_reads_and_truncation(self):
        class ShortReads(io.BytesIO):
            def read(self, size=-1):
                return super().read(min(size, 2))
        self.assertEqual(sap.exact(ShortReads(b"abcdef"), 6), b"abcdef")
        with self.assertRaises(RuntimeError):
            sap.exact(ShortReads(b"abc"), 4)

    def test_cache_changes_with_sdk_compiler_and_options(self):
        command = ["cmake", "sdk-one", "arm64", "target=17.0"]
        key = sap.build_signature(command, "Apple clang one")
        for different in [command + ["new-option"], command[:-1] + ["target=18.0"], ["cmake", "sdk-two", "x86_64"]]:
            self.assertNotEqual(key, sap.build_signature(different, "Apple clang one"))
        self.assertNotEqual(key, sap.build_signature(command, "Apple clang two"))

    def test_atomic_assets_are_checked_by_size_and_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "asset"
            data = b"verified fixture"
            expected = (len(data), hashlib.sha256(data).hexdigest())
            sap.atomic_write(path, data)
            self.assertTrue(sap.valid_asset(path, expected))
            sap.atomic_write(path, b"invalid fixture!")
            self.assertFalse(sap.valid_asset(path, expected))
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_bundled_images_are_compressed_data_with_original_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            assets, resources = Path(directory) / 'assets', Path(directory) / 'bundle'
            assets.mkdir(); resources.mkdir()
            data = b'\xcf\xfa\xed\xfe' + b'Mach-O fixture' * 100
            expected = (len(data), hashlib.sha256(data).hexdigest())
            (assets / 'CoreFP').write_bytes(data)
            (resources / 'CoreFP').write_bytes(b'old raw image')
            with patch.dict(sap.ASSETS, {'CoreFP': expected}, clear=True):
                sap.bundle_assets(assets, resources)
                self.assertFalse((resources / 'CoreFP').exists())
                packed = (resources / 'CoreFP.sapz').read_bytes()
                self.assertNotEqual(packed[:4], data[:4])
                self.assertEqual(zlib.decompress(packed), data)
                sap.bundle_assets(assets, resources)
                self.assertEqual((resources / 'CoreFP.sapz').read_bytes(), packed)


if __name__ == "__main__":
    unittest.main()
