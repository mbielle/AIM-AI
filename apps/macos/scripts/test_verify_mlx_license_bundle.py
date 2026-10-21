import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("mlx_licenses", pathlib.Path(__file__).with_name("verify-mlx-license-bundle.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LicenseBundleTests(unittest.TestCase):
    def fixture(self, root):
        licenses = root / "Licenses"
        licenses.mkdir()
        text = b"Synthetic upstream license text for a packaging test. " * 5
        (licenses / "fixture.txt").write_bytes(text)
        (root / "Package.resolved").write_text(json.dumps({"pins": [{"identity": "fixture", "state": {"revision": "abc"}}]}))
        manifest = {"complete": True, "components": [{"identity": "fixture", "source": "https://example.invalid/fixture", "revision": "abc", "licenses": [{"path": "fixture.txt", "sha256": hashlib.sha256(text).hexdigest()}]}]}
        (licenses / "manifest.json").write_text(json.dumps(manifest))
        return licenses, manifest

    def test_missing_inventory_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                module.verify(directory)

    def test_inventory_and_exact_license_hash_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            licenses, manifest = self.fixture(root)
            self.assertEqual(module.verify(root), 1)
            (licenses / "fixture.txt").write_text("altered")
            with self.assertRaises(ValueError):
                module.verify(root)

    def test_missing_dependency_or_incomplete_review_is_refused(self):
        for change in ["missing", "unreviewed"]:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                licenses, manifest = self.fixture(root)
                if change == "missing":
                    manifest["components"][0]["identity"] = "other"
                else:
                    manifest["complete"] = False
                (licenses / "manifest.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    module.verify(root)

    def test_external_license_path_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            licenses, manifest = self.fixture(root)
            manifest["components"][0]["licenses"][0]["path"] = "../Package.resolved"
            (licenses / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                module.verify(root)


if __name__ == "__main__":
    unittest.main()
