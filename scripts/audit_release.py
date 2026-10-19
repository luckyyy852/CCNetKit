"""Conservative source-only release audit; emits categories, never matched values."""
from __future__ import annotations
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
from release_manifest import FILES, BINARY_SHA256

DOC_NETS = tuple(ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"))
PATTERNS = (
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("node-link", re.compile(r"\b(?:vless|vmess|trojan|ss|hy2|hysteria2)://[^\s\"'<>]+", re.I)),
    ("personal-windows-path", re.compile(r"[A-Za-z]:[\\/]+Users[\\/]+(?!Public\b|Default\b|example\b)[^\\/\"\r\n]+", re.I)),
    ("node-uuid", re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", re.I)),
    ("personal-macos-path", re.compile(r"/" + r"Users/(?!example(?:/|\b)|Shared(?:/|\b))[^/\s\"'<>]+", re.I)),
)
ASSIGNED = re.compile(r"[\"']?(?:api[_-]?key|secret|password|private[_-]?key)[\"']?\s*[:=]\s*[\"']([^\"'\r\n]+)[\"']", re.I)

def findings(text: str, deny_values=()):
    result = {name for name, pattern in PATTERNS if pattern.search(text)}
    for match in ASSIGNED.finditer(text):
        value = match.group(1)
        if not value.lower().startswith(("synthetic-", "your_", "example-")):
            result.add("credential-assignment")
    for candidate in re.findall(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])", text):
        try:
            address = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if not address.is_loopback and address != ipaddress.ip_address("0.0.0.0") and not any(address in net for net in DOC_NETS):
            result.add("non-documentation-ipv4")
    if any(value and len(value) >= 3 and value in text for value in deny_values):
        result.add("local-private-value")
    return sorted(result)

def audit(root: Path, deny_values=()):
    root = root.resolve()
    issues = []
    allowed = set(FILES)
    found = set()
    for path in root.rglob("*"):
        rel = path.relative_to(root).as_posix()
        if ".git" in path.relative_to(root).parts or "__pycache__" in path.relative_to(root).parts:
            continue
        if path.is_symlink() or (getattr(path.lstat(), "st_file_attributes", 0) & 0x400):
            issues.append({"file": rel, "category": "symlink-not-allowed"})
            continue
        if not path.is_file():
            continue
        found.add(rel)
        if rel not in allowed:
            issues.append({"file": rel, "category": "not-in-release-allowlist"})
            continue
        try:
            data = path.read_bytes()
            if rel in BINARY_SHA256:
                if hashlib.sha256(data).hexdigest() != BINARY_SHA256[rel]:
                    issues.append({"file": rel, "category": "reviewed-image-digest-mismatch"})
                continue
            text = data.decode("utf-8-sig")
        except (OSError, UnicodeError):
            issues.append({"file": rel, "category": "not-utf8-source"})
            continue
        for category in findings(text, deny_values):
            issues.append({"file": rel, "category": category})
    for rel in sorted(allowed - found):
        issues.append({"file": rel, "category": "required-file-missing"})
    return {"passed": not issues, "source_files": len((found & allowed) - set(BINARY_SHA256)), "reviewed_images": len(found & set(BINARY_SHA256)), "issues": issues}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--deny-values-file", help="Optional LOCAL-only JSON list; never copy it into the release folder")
    args = parser.parse_args()
    values = json.loads(Path(args.deny_values_file).read_text(encoding="utf-8-sig")) if args.deny_values_file else ()
    result = audit(Path(args.root), values)
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return 0 if result["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
