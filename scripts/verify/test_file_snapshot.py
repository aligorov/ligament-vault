"""Regression coverage for restoring actual volume bytes from an authenticated snapshot."""
import importlib.util
import io
import tempfile
import unittest
import urllib.error
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "ops/file-snapshot.py"
spec = importlib.util.spec_from_file_location("file_snapshot", MODULE)
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class MemoryBucket:
    def __init__(self):
        self.objects = {}

    def call(self, method, bucket, key, body=b""):
        if method == "PUT":
            self.objects[key] = body
            return io.BytesIO()
        if key not in self.objects:
            raise urllib.error.HTTPError("memory://test", 404, "not found", {}, None)
        return io.BytesIO(self.objects[key] if method == "GET" else b"")


class FileRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "original"
        self.dest = self.root / "restored"
        self.source.mkdir()
        self.dest.mkdir()
        self.s3 = MemoryBucket()
        self.archive = self.reopen()
        self.node = "sets/" + "a" * 32 + "/node-1"
        (self.source / "1.dat").write_bytes(b"versioned content")
        (self.source / "1.idx").write_bytes(b"original file IDs")
        snapshot.capture(self.archive, self.node, [self.source])

    def reopen(self):
        return snapshot.Archive(self.s3, "private", "test secret", "test")

    def test_clean_volume_restore_and_retry(self):
        for _ in range(2):
            snapshot.materialize(self.reopen(), self.node, [self.dest], True)
        for name in ("1.dat", "1.idx"):
            self.assertEqual((self.source / name).read_bytes(), (self.dest / name).read_bytes())

    def test_corrupt_block_or_manifest_is_not_reported_as_verified(self):
        for match in ("blocks/", self.node):
            with self.subTest(key=match):
                key = next(k for k in self.s3.objects if match in k)
                original = self.s3.objects[key]
                self.s3.objects[key] = original[:-1] + bytes([original[-1] ^ 1])
                with self.assertRaisesRegex(ValueError, "authentication"):
                    snapshot.materialize(self.reopen(), self.node, [], False)
                self.s3.objects[key] = original

    def test_existing_unrelated_data_survives_rejected_restore(self):
        existing = self.dest / "1.dat"
        existing.write_bytes(b"foreign data")
        with self.assertRaises(ValueError):
            snapshot.materialize(self.reopen(), self.node, [self.dest], True)
        self.assertEqual(existing.read_bytes(), b"foreign data")
        self.assertFalse((self.dest / "1.idx").exists())


if __name__ == "__main__":
    unittest.main()
