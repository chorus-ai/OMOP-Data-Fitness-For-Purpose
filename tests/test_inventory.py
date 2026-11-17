"""Inventory line-ending and exact-byte contract checks."""
import hashlib
from pathlib import Path
import tempfile
import unittest

from omop_fitness.inventory import inventory_sha256


class InventoryHashTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, data):
        path = self.root / name
        path.write_bytes(data)
        return path

    def test_explicit_text_types_treat_crlf_as_lf_only(self):
        for name in ("x.py", "x.md", "x.json", "x.csv", "x.txt", "x.ipynb", ".gitignore", ".gitattributes"):
            with self.subTest(name=name):
                path = self.write(name, b"alpha\nbeta\n")
                reference = inventory_sha256(path)
                path.write_bytes(b"alpha\r\nbeta\r\n")
                self.assertEqual(inventory_sha256(path), reference)
                path.write_bytes(b"alpha\r\nbeta changed\r\n")
                self.assertNotEqual(inventory_sha256(path), reference)
                path.write_bytes(b"alpha\rbeta\n")
                self.assertNotEqual(inventory_sha256(path), reference)

    def test_sql_binary_and_unknown_types_use_exact_bytes(self):
        for name in ("x.sql", "x.docx", "x.pdf", "x.unknown"):
            with self.subTest(name=name):
                data = b"alpha\r\nbeta\r\n"
                path = self.write(name, data)
                self.assertEqual(inventory_sha256(path), hashlib.sha256(data).hexdigest())
                reference = inventory_sha256(path)
                path.write_bytes(data.replace(b"\r\n", b"\n"))
                self.assertNotEqual(inventory_sha256(path), reference)
                path.write_bytes(data + b"x")
                self.assertNotEqual(inventory_sha256(path), reference)

    def test_text_preserves_bom_and_unicode_bytes(self):
        plain = self.write("plain.md", "café\n".encode("utf-8"))
        marked = self.write("marked.md", b"\xef\xbb\xbf" + plain.read_bytes())
        decomposed = self.write("decomposed.md", "cafe\u0301\n".encode("utf-8"))
        self.assertNotEqual(inventory_sha256(plain), inventory_sha256(marked))
        self.assertNotEqual(inventory_sha256(plain), inventory_sha256(decomposed))

    def test_recognized_text_rejects_invalid_utf8(self):
        path = self.write("invalid.md", b"bad \xff")
        with self.assertRaises(UnicodeDecodeError):
            inventory_sha256(path)


if __name__ == "__main__":
    unittest.main()
