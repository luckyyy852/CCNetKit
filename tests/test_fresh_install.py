"""Build/extract the real allowlist, then exercise installed macOS entry points."""
from pathlib import Path
import hashlib
import http.client
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import urlsplit
import zipfile

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE / "scripts"))
from package_release import package
from release_manifest import FILES


class FreshInstall(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="workbench-fresh-")
        self.base = Path(self.temp.name).resolve()
        archive = self.base / "release.zip"
        package(SOURCE, archive)
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(set(z.namelist()), {"windows-network-workbench/" + f for f in FILES})
            z.extractall(self.base / "New user 下载目录")
        self.source = self.base / "New user 下载目录/windows-network-workbench"

    def tearDown(self):
        self.temp.cleanup()

    def run_entry(self, *args):
        return subprocess.run([sys.executable, str(self.source / "scripts/workbench.py"), *args],
                              capture_output=True, timeout=30, cwd=self.base)

    def test_unpack_and_detect_from_unrelated_working_directory(self):
        self.assertTrue((self.source / "SKILL.md").is_file())
        result = self.run_entry("detect")
        self.assertEqual(result.returncode, 0)
        expected = "macOS" if sys.platform == "darwin" else "Windows"
        self.assertEqual(json.loads(result.stdout)["platform"], expected)
        self.assertFalse((self.source / "settings.json").exists())

    @unittest.skipUnless(sys.platform == "darwin", "Actual Mac install/startup requires macOS")
    def test_mac_installed_launcher_ui_and_route_roundtrip(self):
        private = self.base / "Private user 用户"
        private.mkdir(mode=0o700)
        core = private / "synthetic-core"
        core.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        core.chmod(0o700)
        protected = private / "protected.env"
        protected.write_text("synthetic-only", encoding="utf-8")
        config = private / "daily.json"
        cfg = {"mode": "rule", "external-controller": "127.0.0.1:19099",
               "secret": "synthetic-local-token", "tun": {"enable": False},
               "rules": ["DOMAIN,relay.example,DIRECT", "MATCH,PROXY"]}
        config.write_text(json.dumps(cfg), encoding="utf-8")
        settings = private / "settings.json"
        settings.write_text(json.dumps({"SchemaVersion": 1, "Profiles": [{"Name": "Synthetic offline core",
            "ConfigPath": str(config), "ExecutablePath": str(core), "DataDirectory": str(private),
            "Reload": False, "ManageRules": True, "ProtectedRules": [cfg["rules"][0]]}],
            "ProtectedFiles": [str(protected)]}), encoding="utf-8")
        before = hashlib.sha256(settings.read_bytes()).digest()
        install = self.base / "Installed user 用户"
        result = self.run_entry("install", "--root", str(install), "--settings", str(settings))
        self.assertEqual(result.returncode, 0, "Extracted Mac installer failed")
        self.assertFalse(json.loads(result.stdout)["network_changed"])
        self.assertEqual(hashlib.sha256((install / "settings.json").read_bytes()).digest(), before)
        self.assertEqual(install.stat().st_mode & 0o777, 0o700)
        self.assertEqual((install / "settings.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(subprocess.run(["/bin/sh", "-n", str(install / "Open Workbench.command")],
                                       capture_output=True).returncode, 0)
        runtime = install / "bin/mac_workbench.py"
        check = subprocess.run([sys.executable, str(runtime), "--root", str(install), "--inspect"],
                               capture_output=True, timeout=15)
        self.assertEqual(check.returncode, 0)
        log = private / "startup.txt"
        with log.open("wb") as output:
            child = subprocess.Popen([sys.executable, "-u", str(runtime), "--root", str(install), "--no-open"],
                                     stdout=output, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            address = None
            while time.monotonic() < deadline:
                self.assertIsNone(child.poll(), "Installed local UI exited during startup")
                address = next((s for s in log.read_text(encoding="utf-8").splitlines()
                                if s.startswith("http://127.0.0.1:")), None)
                if address:
                    break
                time.sleep(0.05)
            self.assertIsNotNone(address, "Installed UI did not publish a private session address")
            url = urlsplit(address)
            def request(method, path, value=None, authenticated=True):
                headers = {}
                if authenticated:
                    headers["Authorization"] = "Bearer " + url.fragment
                if value is not None:
                    headers.update({"Origin": "http://" + url.netloc, "Content-Type": "application/json"})
                conn = http.client.HTTPConnection("127.0.0.1", url.port, timeout=10)
                try:
                    conn.request(method, path, json.dumps(value) if value is not None else None, headers)
                    response = conn.getresponse()
                    return response.status, response.read()
                finally:
                    conn.close()
            self.assertEqual(request("GET", "/", authenticated=False)[0], 200)
            self.assertEqual(request("GET", "/api/state", authenticated=False)[0], 403)
            status, body = request("GET", "/api/state")
            self.assertEqual(status, 200)
            self.assertTrue(json.loads(body)["errors"], "Offline core must not be reported as connected")
            self.assertNotIn(cfg["secret"].encode(), body)
            for action in ("Direct", "Default"):
                status, _ = request("POST", "/api/route", {"domain": "example.com", "action": action})
                self.assertEqual(status, 200)
            self.assertEqual(json.loads(config.read_text()), cfg)
            self.assertEqual(protected.read_text(), "synthetic-only")
            self.assertNotEqual(self.run_entry("install", "--root", str(install),
                                              "--settings", str(settings)).returncode, 0)
            self.assertEqual(hashlib.sha256((install / "settings.json").read_bytes()).digest(), before)
        finally:
            child.terminate()
            child.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
