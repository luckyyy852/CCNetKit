"""macOS local workbench. No third-party packages, core startup or system changes."""
from __future__ import annotations
import argparse
import base64
import copy
import hashlib
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, HTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import webbrowser
sys.dont_write_bytecode = True


class Refused(Exception):
    """Safe, user-facing failure without printing configuration or core output."""


def external_path(path, source, exists=True):
    path = Path(path)
    if not path.is_absolute() or path == source or source in path.resolve().parents:
        raise ValueError("Private files must be outside the skill source")
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError("Symbolic private paths are not supported")
    if exists and not path.exists():
        raise ValueError("Required private path is missing")
    return path.resolve()


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def atomic_write(path, data):
    path = Path(path)
    fd, temp = tempfile.mkstemp(prefix=".workbench-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def controller(config):
    url = urlsplit("http://" + str(config.get("external-controller", "")))
    try:
        valid = (url.hostname == "127.0.0.1" and url.port and not url.username
                 and url.path == "" and not url.query and not url.fragment)
    except ValueError:
        valid = False
    if not valid or not config.get("secret"):
        raise ValueError("Use an authenticated IPv4 loopback controller")
    return url.port


def inspect_settings(path, source):
    path = external_path(path, source)
    if not path.is_file():
        raise ValueError("Settings must be a file")
    settings = read_json(path)
    profiles = settings.get("Profiles")
    if settings.get("SchemaVersion") != 1 or not isinstance(profiles, list) or not profiles:
        raise ValueError("Invalid settings schema")
    protected = [external_path(Path(p), source) for p in settings.get("ProtectedFiles", [])]
    seen = set()
    for profile in profiles:
        cfg_path = external_path(Path(profile["ConfigPath"]), source)
        exe = external_path(Path(profile["ExecutablePath"]), source)
        data = external_path(Path(profile["DataDirectory"]), source)
        if not cfg_path.is_file() or not exe.is_file() or not data.is_dir():
            raise ValueError("Invalid profile paths")
        if cfg_path in protected or cfg_path in seen:
            raise ValueError("Protected or duplicate editable config")
        seen.add(cfg_path)
        cfg = read_json(cfg_path)
        if cfg.get("mode", "").lower() != "rule" or not isinstance(cfg.get("rules"), list):
            raise ValueError("Use a rule-mode JSON configuration")
        controller(cfg)
        if any(rule not in cfg["rules"] for rule in profile.get("ProtectedRules", [])):
            raise ValueError("Protected rule is absent")
    return settings


def normalize_domain(text):
    text = text.strip()
    if not text or re.search(r"[\s*\"'<>]", text):
        raise ValueError("Invalid domain")
    url = urlsplit(text if "://" in text else "https://" + text)
    if url.scheme not in ("http", "https") or url.username or url.password:
        raise ValueError("Use an http/https URL or domain")
    host = (url.hostname or "").rstrip(".").encode("idna").decode("ascii").lower()
    # Access port to reject malformed URLs before accepting the host.
    _ = url.port
    if host.startswith("www."):
        host = host[4:]
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("IP addresses are not domains")
    if len(host) > 253 or host.endswith(".exe") or not re.fullmatch(
            r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?", host):
        raise ValueError("Use a complete domain")
    return host


def edit_rules(rules, managed, domain, action):
    owned = set(managed)
    exact = "DOMAIN-SUFFIX," + domain + ",DIRECT"
    if action == "Direct" and domain not in owned and exact in rules:
        return list(rules), sorted(owned)
    base = [r for r in rules if r not in {"DOMAIN-SUFFIX," + d + ",DIRECT" for d in owned}]
    if action == "Direct":
        owned.add(domain)
    elif action == "Default":
        owned.discard(domain)
    else:
        raise ValueError("Unknown action")
    index = next((i for i, r in enumerate(base) if re.match(r"^(GEOSITE|GEOIP|RULE-SET|MATCH),", r)), None)
    if index is None:
        raise ValueError("No safe rule insertion point")
    return base[:index] + ["DOMAIN-SUFFIX," + d + ",DIRECT" for d in sorted(owned)] + base[index:], sorted(owned)


def api(config, method, path, body=None):
    # http.client does not inherit system/HTTP proxy environment variables or follow redirects.
    connection = http.client.HTTPConnection("127.0.0.1", controller(config), timeout=4)
    try:
        data = json.dumps(body).encode() if body is not None else None
        connection.request(method, path, data, {"Authorization": "Bearer " + config["secret"],
                                                "Content-Type": "application/json"})
        response = connection.getresponse()
        payload = response.read(8 * 1024 * 1024 + 1)
        if not 200 <= response.status < 300 or len(payload) > 8 * 1024 * 1024:
            raise Refused("本机控制器请求失败。")
        return json.loads(payload) if payload else {}
    finally:
        connection.close()


def mac_identity(profile, config):
    """Verify the exact listener owner, executable and process start time, never by process name."""
    port = controller(config)
    listing = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-iTCP:" + str(port),
                              "-sTCP:LISTEN", "-Fpn"], capture_output=True, text=True, timeout=5)
    pids, endpoints = set(), []
    for line in listing.stdout.splitlines():
        if line.startswith("p"):
            pids.add(line[1:])
        elif line.startswith("n"):
            endpoints.append(line[1:])
    if len(pids) != 1 or not endpoints or any(e != "127.0.0.1:" + str(port) for e in endpoints):
        raise Refused("无法确认核心监听身份；没有修改规则。")
    pid = next(iter(pids))
    details = subprocess.run(["/usr/sbin/lsof", "-a", "-p", pid, "-d", "txt", "-Fn"],
                             capture_output=True, text=True, timeout=5)
    expected = str(Path(profile["ExecutablePath"]).resolve())
    files = [line[1:] for line in details.stdout.splitlines() if line.startswith("n")]
    started = subprocess.run(["/bin/ps", "-p", pid, "-o", "lstart="],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    if not started or expected not in files:
        raise Refused("核心路径不匹配；没有修改规则。")
    return pid, started, expected


class Workbench:
    def __init__(self, root, source=None, identity=mac_identity, validate=None):
        self.root = Path(root).resolve()
        self.source = Path(source).resolve() if source else Path(__file__).resolve().parent
        if (self.root / "SKILL.md").exists():
            raise ValueError("Do not run from the source folder")
        self.settings_path = self.root / "settings.json"
        self.settings = inspect_settings(self.settings_path, self.source)
        self.identity = identity
        self.validate = validate or self.core_validate
        self.history = {}
        self.routes_path = self.root / "data/routes.json"
        external_path(self.routes_path, self.source)
        self.pending_path = self.root / "data/pending.json"
        self.disabled = self.pending_path.exists()

    def core_validate(self, profile):
        result = subprocess.run([profile["ExecutablePath"], "-t", "-d", profile["DataDirectory"],
                                 "-f", profile["ConfigPath"]], capture_output=True, timeout=30)
        if result.returncode:
            raise Refused("Mihomo 配置校验失败；原配置已恢复。")

    def state(self):
        rows, errors = [], []
        now = time.monotonic()
        for profile in self.settings["Profiles"]:
            try:
                config = read_json(profile["ConfigPath"])
                before = self.identity(profile, config)
                runtime = api(config, "GET", "/configs")
                if str(runtime.get("mode", "")).lower() != "rule":
                    raise Refused("核心没有处于规则模式。")
                connections = api(config, "GET", "/connections").get("connections", [])
                if before != self.identity(profile, config):
                    raise Refused("核心身份发生变化。")
                for item in connections:
                    meta = item.get("metadata", {})
                    chains = item.get("chains", [])
                    route = "直连" if "DIRECT" in chains else ("拒绝" if "REJECT" in chains else "代理")
                    key = profile["ConfigPath"] + str(item.get("id", ""))
                    row = {"app": meta.get("process") or meta.get("processPath") or "未知",
                           "host": meta.get("host") or meta.get("destinationIP", ""),
                           "route": route, "protocol": meta.get("network", ""),
                           "down": item.get("download", 0), "up": item.get("upload", 0),
                           "state": "连接中", "profile": profile["Name"]}
                    self.history[key] = (now, row)
                    rows.append(key)
            except Exception:
                errors.append(profile["Name"] + "：控制器离线或身份未通过检查")
        self.history = dict(sorted(((k, v) for k, v in self.history.items() if now - v[0] < 600),
                                   key=lambda item: item[1][0], reverse=True)[:1000])
        output = []
        for key, (_, saved) in self.history.items():
            row = dict(saved)
            if key not in rows:
                row["state"] = "近期记录"
            output.append(row)
        return {"rows": output, "errors": errors, "writeDisabled": self.disabled,
                "protection": "此窗口不解锁或替代专用应用保护。"}

    def change(self, text, action):
        if self.disabled or self.pending_path.exists():
            raise Refused("上次回退未能确认，已停用写入；请检查私人运行目录。")
        # Single HTTPServer serializes requests. flock also excludes another workbench instance.
        import fcntl
        with (self.root / "data/change.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self._change(text, action)

    def _change(self, text, action):
        domain = normalize_domain(text)
        inspect_settings(self.settings_path, self.source)
        if read_json(self.settings_path) != self.settings:
            raise Refused("设置已变更，请重新打开工作台。")
        protected = {Path(p): digest(p) for p in self.settings.get("ProtectedFiles", [])}
        # Existing protection status/lock must remain byte-for-byte untouched.
        protection = self.settings.get("Protection") or {}
        for key in ("GuardStatePath", "LockPath"):
            if protection.get(key):
                p = external_path(Path(protection[key]), self.source, exists=False)
                protected[p] = digest(p) if p.exists() else None
        registry_raw = self.routes_path.read_bytes()
        registry = json.loads(registry_raw)
        owned_by_profile = registry.setdefault("Profiles", {})
        changes = []
        for profile in self.settings["Profiles"]:
            if not profile.get("ManageRules", True):
                continue
            path = Path(profile["ConfigPath"])
            raw = path.read_bytes()
            cfg = json.loads(raw)
            owned = owned_by_profile.get(str(path), [])
            expected = {"DOMAIN-SUFFIX," + d + ",DIRECT" for d in owned}
            if not expected.issubset(cfg["rules"]):
                raise Refused("已有受管规则被外部修改；没有覆盖。")
            edited, owned_next = edit_rules(cfg["rules"], owned, domain, action)
            new = copy.deepcopy(cfg)
            new["rules"] = edited
            if any(rule not in edited for rule in profile.get("ProtectedRules", [])):
                raise Refused("操作会影响预设保护规则，已拒绝。")
            identity = None
            if profile.get("Reload", True):
                identity = self.identity(profile, cfg)
                if api(cfg, "GET", "/configs").get("mode", "").lower() != "rule":
                    raise Refused("核心没有处于规则模式。")
            changes.append((profile, path, raw, cfg, new, identity))
            owned_by_profile[str(path)] = owned_next
        if not changes:
            raise Refused("没有可管理的日常配置。")
        journal = {"SchemaVersion": 1, "RegistryBefore": base64.b64encode(registry_raw).decode("ascii"),
                   "ConfigsBefore": [{"Path": str(path), "Bytes": base64.b64encode(raw).decode("ascii")}
                                     for _, path, raw, _, _, _ in changes]}
        # One private, bounded recovery file. A crash requires review before further edits.
        atomic_write(self.pending_path, json.dumps(journal).encode())
        touched, reloaded = [], []
        try:
            for profile, path, raw, cfg, new, identity in changes:
                if path.read_bytes() != raw:
                    raise Refused("配置同时被其他程序修改。")
                if new != cfg:
                    atomic_write(path, (json.dumps(new, ensure_ascii=False, indent=2) + "\n").encode())
                    touched.append((path, raw))
                    self.validate(profile)
                for p, original_hash in protected.items():
                    if (digest(p) if p.exists() else None) != original_hash:
                        raise Refused("保护状态发生变化，停止操作。")
                if identity:
                    if self.identity(profile, cfg) != identity:
                        raise Refused("核心身份发生变化。")
                    reloaded.append((profile, cfg, identity))
                    api(cfg, "PUT", "/configs?force=false", {"path": str(path)})
                    rules = api(cfg, "GET", "/rules").get("rules", [])
                    wanted = domain in owned_by_profile[str(path)]
                    found = any(r.get("type") == "DomainSuffix" and r.get("payload") == domain
                                and r.get("proxy") == "DIRECT" for r in rules)
                    preexisting = "DOMAIN-SUFFIX," + domain + ",DIRECT" in cfg["rules"] and domain not in json.loads(registry_raw).get("Profiles", {}).get(str(path), [])
                    if found != (wanted or preexisting):
                        raise Refused("运行规则未通过检查。")
            for p, original_hash in protected.items():
                if (digest(p) if p.exists() else None) != original_hash:
                    raise Refused("保护状态发生变化，停止操作。")
            atomic_write(self.routes_path, (json.dumps(registry, ensure_ascii=False, indent=2) + "\n").encode())
        except Exception:
            rollback_failed = False
            for path, raw in reversed(touched):
                try:
                    atomic_write(path, raw)
                except Exception:
                    rollback_failed = True
            for profile, cfg, identity in reversed(reloaded):
                try:
                    if self.identity(profile, cfg) != identity:
                        raise Refused("Core changed")
                    api(cfg, "PUT", "/configs?force=false", {"path": profile["ConfigPath"]})
                except Exception:
                    rollback_failed = True
            self.disabled = rollback_failed
            if not rollback_failed:
                self.pending_path.unlink(missing_ok=True)
            raise Refused("修改失败；" + ("回退未能确认，已停用写入。" if rollback_failed else "已恢复原配置。")) from None
        try:
            self.pending_path.unlink(missing_ok=True)
        except OSError:
            self.disabled = True
            raise Refused("规则已保存，但恢复记录清理失败，已停用后续写入。") from None
        parent = next((d for values in owned_by_profile.values() for d in values if domain.endswith("." + d)), None)
        return {"ok": True, "message": "规则已保存并检查。" + ("该域名仍继承父域直连规则。" if parent and action == "Default" else "")}


def make_server(workbench, page):
    token = secrets.token_urlsafe(32)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, payload, content_type="application/json; charset=utf-8"):
            data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def allowed(self, mutation=False):
            host = "127.0.0.1:" + str(self.server.server_port)
            if self.headers.get("Host") != host:
                return False
            origin = self.headers.get("Origin")
            if origin and origin != "http://" + host:
                return False
            if mutation and origin != "http://" + host:
                return False
            return hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token)

        def do_GET(self):
            if self.path == "/" and self.headers.get("Host") == "127.0.0.1:" + str(self.server.server_port):
                self.send(200, page, "text/html; charset=utf-8")
            elif self.path == "/api/state" and self.allowed():
                try:
                    self.send(200, workbench.state())
                except Exception:
                    self.send(503, {"message": "读取状态失败，请检查本机配置。"})
            else:
                self.send(403, {"message": "请求未授权。"})

        def do_POST(self):
            if self.path != "/api/route" or not self.allowed(True):
                self.send(403, {"message": "请求未授权。"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096 or self.headers.get("Content-Type") != "application/json":
                    raise ValueError("Invalid request")
                request = json.loads(self.rfile.read(length))
                self.send(200, workbench.change(request["domain"], request["action"]))
            except Refused as exc:
                self.send(409, {"message": str(exc)})
            except Exception:
                self.send(400, {"message": "操作未完成，请检查域名、文件权限和核心状态。"})

    server = HTTPServer(("127.0.0.1", 0), Handler)
    return server, "http://127.0.0.1:" + str(server.server_port) + "/#" + token


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise Refused("请在 Mac 上运行此入口；Windows 使用原窗口。")
    if os.geteuid() == 0:
        raise Refused("请用普通用户运行，不要 sudo。")
    root = Path(args.root).expanduser()
    source = Path(__file__).resolve().parent
    if args.inspect:
        inspect_settings(root / "settings.json", source)
        print("本机设置检查通过；未发送网络请求。")
        return
    workbench = Workbench(root)
    page = Path(__file__).with_name("mac_ui.html").read_bytes()
    server, address = make_server(workbench, page)
    print("本地管理界面已启动；关闭此进程即停止管理界面，不会停止原网络。")
    if not args.no_open:
        webbrowser.open(address)
    else:
        # Session URL is a local capability. Do not put it in public logs or screenshots.
        print(address)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("工作台未启动。请检查私人设置、Python 版本及文件权限。", file=sys.stderr)
        raise SystemExit(1)
