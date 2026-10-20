"""Synthetic files and loopback HTTP only; no real core, browser, TUN or account."""
from __future__ import annotations
from contextlib import contextmanager
import copy
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOURCE / "assets/runtime"))
sys.path.insert(0, str(SOURCE / "scripts"))
import mac_workbench as app
import workbench as entry


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer synthetic-loopback-token":
            self.send_error(403)
            return
        cfg = app.read_json(self.server.config)
        if self.path == "/configs":
            self.answer({"mode": "rule"})
        elif self.path == "/rules":
            if self.server.fail_verify:
                self.send_error(500)
                return
            rules = []
            for r in cfg["rules"]:
                parts = r.split(",")
                if parts[0] == "DOMAIN-SUFFIX":
                    rules.append({"type": "DomainSuffix", "payload": parts[1], "proxy": parts[2]})
            self.answer({"rules": rules})
        elif self.path == "/connections":
            self.answer({"connections": [{"id": "synthetic-row", "metadata": {
                "process": "Example.app", "host": "example.com", "network": "TCP"},
                "chains": ["DIRECT"], "download": 12, "upload": 34}]})
        else:
            self.send_error(404)

    def do_PUT(self):
        if self.path != "/configs?force=false":
            self.send_error(404)
            return
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.reloads.append(data)
        self.answer({})


@contextmanager
def running(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class MacTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="synthetic-workbench-")
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir()
        self.root = self.base / "installed"
        (self.root / "data").mkdir(parents=True)
        self.config = self.base / "daily.json"
        self.exe = self.base / "synthetic-core"
        self.exe.write_text("not executable and never launched")
        self.protected = self.base / "private.env"
        self.protected.write_text("synthetic-only")
        self.cfg = {"mode": "rule", "external-controller": "127.0.0.1:19099",
                    "secret": "synthetic-loopback-token", "tun": {"enable": False},
                    "rules": ["DOMAIN,relay.example.com,DIRECT", "GEOSITE,cn,DIRECT", "MATCH,PROXY"]}
        self.profile = {"Name": "Synthetic", "ConfigPath": str(self.config),
                        "ExecutablePath": str(self.exe), "DataDirectory": str(self.base),
                        "ManageRules": True, "Reload": False,
                        "ProtectedRules": [self.cfg["rules"][0]]}
        self.settings = {"SchemaVersion": 1, "Profiles": [self.profile], "ProtectedFiles": [str(self.protected)]}
        self.save()
        app.atomic_write(self.root / "data/routes.json", b'{"SchemaVersion":1,"Profiles":{}}')

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        self.config.write_text(json.dumps(self.cfg), encoding="utf-8")
        (self.root / "settings.json").write_text(json.dumps(self.settings), encoding="utf-8")

    def instance(self, **kwargs):
        return app.Workbench(self.root, source=self.source, validate=lambda p: None, **kwargs)

    def test_auto_platform_and_unsupported(self):
        self.assertEqual(entry.plan("Windows")["installer"], "Install-Workbench.ps1")
        self.assertEqual(entry.plan("Darwin")["interface"], "loopback-web")
        with self.assertRaises(ValueError):
            entry.plan("Linux")

    def test_windows_dispatch_keeps_existing_installer(self):
        with patch.object(entry.platform, "system", return_value="Windows"), patch.object(entry.subprocess, "call", return_value=0) as call, patch.object(sys, "argv", ["workbench.py", "install", "--root", "synthetic-target", "--settings", "synthetic-settings"]):
            self.assertEqual(entry.main(), 0)
            args = call.call_args.args[0]
            self.assertTrue(args[3].endswith("Install-Workbench.ps1"))
            self.assertEqual(args[-4:], ["-InstallRoot", "synthetic-target", "-SettingsPath", "synthetic-settings"])

    def test_readonly_inspect(self):
        before = self.config.read_bytes()
        app.inspect_settings(self.root / "settings.json", self.source)
        self.assertEqual(before, self.config.read_bytes())

    def test_path_and_controller_refusals(self):
        for host in ("0.0.0.0:9090", "192.0.2.10:9090", "localhost:9090", "127.0.0.1:9090/path"):
            with self.assertRaises(ValueError):
                app.controller({"external-controller": host, "secret": "synthetic-only"})
        with self.assertRaises(ValueError):
            app.external_path(self.source / "settings.json", self.source, False)

    def test_domains(self):
        self.assertEqual(app.normalize_domain("https://www.Example.com/a?q=b"), "example.com")
        self.assertTrue(app.normalize_domain("例子.中国").startswith("xn--"))
        for bad in ("127.0.0.1", "node.exe", "com", "*.example.com", "https://user:pass@example.com", "ftp://example.com", "https://example.com:invalid"):
            with self.assertRaises(ValueError):
                app.normalize_domain(bad)

    def test_rules_restore_and_preexisting_ownership(self):
        rules, owned = app.edit_rules(self.cfg["rules"], [], "example.com", "Direct")
        self.assertEqual(rules[0], self.cfg["rules"][0])
        restored, owned = app.edit_rules(rules, owned, "example.com", "Default")
        self.assertEqual(restored, self.cfg["rules"])
        preset = ["DOMAIN-SUFFIX,example.com,DIRECT"] + self.cfg["rules"]
        self.assertEqual(app.edit_rules(preset, [], "example.com", "Direct"), (preset, []))
        self.assertEqual(app.edit_rules(preset, [], "example.com", "Default"), (preset, []))

    @unittest.skipIf(sys.platform == "win32", "flock is macOS/POSIX; exercised by macOS CI")
    def test_change_api_serializes_and_saves(self):
        self.instance().change("example.com", "Direct")
        self.assertIn("DOMAIN-SUFFIX,example.com,DIRECT", app.read_json(self.config)["rules"])

    def test_transaction_retains_relay_and_protected_file(self):
        before = self.protected.read_bytes()
        window = self.instance()
        window._change("example.com", "Direct")
        self.assertEqual(app.read_json(self.config)["rules"][0], self.profile["ProtectedRules"][0])
        window._change("example.com", "Default")
        self.assertEqual(app.read_json(self.config), self.cfg)
        self.assertEqual(self.protected.read_bytes(), before)

    def test_validation_failure_rolls_back_exact_bytes(self):
        before = self.config.read_bytes()
        window = self.instance()
        window.validate = lambda p: (_ for _ in ()).throw(app.Refused("synthetic-failure"))
        with self.assertRaises(app.Refused):
            window._change("example.com", "Direct")
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(app.read_json(window.routes_path)["Profiles"], {})
        self.assertFalse(window.pending_path.exists())

    def test_interrupted_transaction_blocks_later_changes(self):
        app.atomic_write(self.root / "data/pending.json", b'{"SchemaVersion":1}')
        window = self.instance()
        self.assertTrue(window.state()["writeDisabled"])
        with self.assertRaises(app.Refused):
            window.change("example.com", "Direct")

    def test_second_profile_failure_restores_first_profile(self):
        second = self.base / "second.json"
        second.write_bytes(self.config.read_bytes())
        other = copy.deepcopy(self.profile)
        other["ConfigPath"] = str(second)
        self.settings["Profiles"].append(other)
        self.save()
        before = self.config.read_bytes()
        window = self.instance()
        def validate(profile):
            if profile["ConfigPath"] == str(second):
                raise app.Refused("synthetic-second-validation-failure")
        window.validate = validate
        with self.assertRaises(app.Refused):
            window._change("example.com", "Direct")
        self.assertEqual(before, self.config.read_bytes())
        self.assertEqual(before, second.read_bytes())
        self.assertFalse(window.pending_path.exists())

    def test_protection_state_change_rolls_back_without_overwriting_guard(self):
        state = self.base / "guard.json"
        state.write_text('{"status":"synthetic-running"}')
        self.settings["Protection"] = {"GuardStatePath": str(state)}
        self.save()
        window = self.instance()
        before = self.config.read_bytes()
        def validate(profile):
            state.write_text('{"status":"synthetic-locked"}')
        window.validate = validate
        with self.assertRaises(app.Refused):
            window._change("example.com", "Direct")
        self.assertEqual(before, self.config.read_bytes())
        self.assertEqual(app.read_json(state)["status"], "synthetic-locked")

    def test_profile_change_rejected(self):
        window = self.instance()
        self.settings["Profiles"][0]["Name"] = "Changed"
        self.save()
        with self.assertRaises(app.Refused):
            window._change("example.com", "Direct")

    def test_listener_identity_rejects_wrong_owner_or_wildcard(self):
        def output(text):
            return type("Result", (), {"stdout": text})()
        with patch.object(app.subprocess, "run", side_effect=[output("p123\nn127.0.0.1:19099\n"), output("n" + str(self.exe) + "\n"), output("synthetic-start")]):
            self.assertEqual(app.mac_identity(self.profile, self.cfg), ("123", "synthetic-start", str(self.exe)))
        with patch.object(app.subprocess, "run", return_value=output("p123\nn*:19099\n")):
            with self.assertRaises(app.Refused):
                app.mac_identity(self.profile, self.cfg)

    def test_reload_and_verification_rollback(self):
        server = HTTPServer(("127.0.0.1", 0), Stub)
        server.config, server.reloads, server.fail_verify = self.config, [], False
        self.cfg["external-controller"] = "127.0.0.1:" + str(server.server_port)
        self.profile["Reload"] = True
        self.save()
        with running(server):
            window = self.instance(identity=lambda p, c: (123, "synthetic-start", str(self.exe)))
            window._change("example.com", "Direct")
            self.assertEqual(len(server.reloads), 1)
            before = self.config.read_bytes()
            server.fail_verify = True
            with self.assertRaises(app.Refused):
                window._change("other.example", "Direct")
            self.assertEqual(before, self.config.read_bytes())
            self.assertEqual(len(server.reloads), 3)
            state = window.state()
            self.assertEqual(state["rows"][0]["route"], "直连")
            self.assertNotIn("secret", json.dumps(state))

    def test_local_ui_startup_does_not_resolve_dns(self):
        with patch("socket.getfqdn", side_effect=AssertionError("Local UI must not resolve DNS")):
            server, _ = app.make_server(self.instance(), b"synthetic-ui")
        try:
            self.assertEqual(server.server_address[0], "127.0.0.1")
            self.assertEqual(server.server_port, server.server_address[1])
            self.assertGreater(server.server_port, 0)
        finally:
            server.server_close()

    def test_http_session_authorization_origin_and_no_secret_response(self):
        window = self.instance()
        server, url = app.make_server(window, b"synthetic-ui")
        token = url.split("#")[1]
        host = "127.0.0.1:" + str(server.server_port)
        with running(server):
            def request(method, path, headers=None, body=None):
                conn = http.client.HTTPConnection("127.0.0.1", server.server_port)
                conn.request(method, path, body=body, headers=headers or {})
                response = conn.getresponse()
                result = response.status, response.read()
                conn.close()
                return result
            self.assertEqual(request("GET", "/api/state")[0], 403)
            auth = {"Authorization": "Bearer " + token}
            status, payload = request("GET", "/api/state", auth)
            self.assertEqual(status, 200)
            self.assertNotIn(self.cfg["secret"].encode(), payload)
            self.assertEqual(request("GET", "/api/state", dict(auth, Host="evil.example"))[0], 403)
            self.assertEqual(request("POST", "/api/route", dict(auth, Origin="https://evil.example"), b"{}")[0], 403)
            self.assertEqual(request("POST", "/api/route", auth, b"{}")[0], 403)
            self.assertEqual(request("POST", "/api/route", dict(auth, Origin="http://" + host, **{"Content-Type": "application/json"}), b"{}")[0], 400)

    def test_install_uses_new_directory_and_private_permissions(self):
        destination = self.base / "new-install"
        before = self.config.read_bytes()
        result = entry.install_mac(destination, self.root / "settings.json")
        self.assertFalse(result["network_changed"])
        self.assertTrue((destination / "Open Workbench.command").exists())
        self.assertEqual((destination / "Open CCNetKit.command").read_bytes(),
                         (destination / "Open Workbench.command").read_bytes())
        self.assertEqual(self.config.read_bytes(), before)
        # Installed runtime must not incorrectly treat its parent as the skill source.
        app.Workbench(destination, source=destination / "bin")
        if sys.platform != "win32":
            self.assertEqual((destination / "settings.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        with self.assertRaises(ValueError):
            entry.install_mac(destination, self.root / "settings.json")


if __name__ == "__main__":
    unittest.main()
