"""Privacy scanner behavior tests, using synthetic strings only."""
from pathlib import Path
import sys
import unittest
import shutil
import tempfile
import zipfile
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from audit_release import findings
from audit_release import audit
from package_release import package
from release_manifest import FILES

class ReleaseTests(unittest.TestCase):
    def test_documentation_addresses_are_allowed(self):
        self.assertEqual(findings("127.0.0.1 192.0.2.10 198.51.100.1 203.0.113.2"), [])

    def test_private_values_are_not_echoed(self):
        value = "synthetic-private-marker"
        result = findings("some " + value, [value])
        self.assertEqual(result, ["local-private-value"])
        self.assertNotIn(value, str(result))

    def test_live_node_address_is_rejected(self):
        value = ".".join(map(str, (8, 8, 4, 4)))
        self.assertIn("non-documentation-ipv4", findings(value))

    def test_credentials_rejected(self):
        name = "sec" + "ret"
        text = '"' + name + '": "not-a-real-credential"'
        self.assertIn("credential-assignment", findings(text))

    def test_synthetic_fixture_allowed(self):
        self.assertEqual(findings('secret="synthetic-local-token"'), [])

    def test_personal_macos_path_rejected(self):
        self.assertIn("personal-macos-path", findings("/" + "Users/" + "private-person/secret.json"))
        self.assertEqual(findings("/Users/example/PrivateNetwork/settings.json"), [])

    def copy_source(self, destination):
        source = Path(__file__).resolve().parents[1]
        for name in FILES:
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, target)

    def test_unknown_runtime_file_blocks_release(self):
        with tempfile.TemporaryDirectory(prefix="workbench-release-test-") as temp:
            base = Path(temp)
            root = base / "source"
            self.copy_source(root)
            (root / ".env").write_text("synthetic-only", encoding="utf-8")
            self.assertFalse(audit(root)["passed"])
            with self.assertRaises(ValueError):
                package(root, base / "blocked.zip")
            self.assertFalse((base / "blocked.zip").exists())

    def test_detected_credential_blocks_release(self):
        with tempfile.TemporaryDirectory(prefix="workbench-release-test-") as temp:
            base = Path(temp)
            root = base / "source"
            self.copy_source(root)
            text = '"' + "sec" + 'ret": "not-a-real-credential"'
            (root / "README.md").write_text(text, encoding="utf-8")
            with self.assertRaises(ValueError):
                package(root, base / "blocked.zip")
            self.assertFalse((base / "blocked.zip").exists())

    def test_archive_contains_exact_allowlist(self):
        with tempfile.TemporaryDirectory(prefix="workbench-release-test-") as temp:
            base = Path(temp)
            root = base / "source"
            self.copy_source(root)
            output = base / "release.zip"
            package(root, output)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(set(archive.namelist()), {"windows-network-workbench/" + name for name in FILES})
            self.assertTrue(output.with_suffix(".zip.sha256").exists())

    def test_changed_demo_image_blocks_release(self):
        with tempfile.TemporaryDirectory(prefix="workbench-release-test-") as temp:
            base = Path(temp)
            root = base / "source"
            self.copy_source(root)
            image = root / "assets/workbench-demo.png"
            image.write_bytes(image.read_bytes() + b"unreviewed-image-metadata")
            self.assertFalse(audit(root)["passed"])
            with self.assertRaises(ValueError):
                package(root, base / "blocked.zip")
            self.assertFalse((base / "blocked.zip").exists())

if __name__ == "__main__":
    unittest.main()
