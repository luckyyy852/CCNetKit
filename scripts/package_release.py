"""Audit, then package the source allowlist. Never zip an installation tree."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile
sys.dont_write_bytecode = True
from audit_release import audit
from release_manifest import FILES

def package(root: Path, output: Path):
    root, output = root.resolve(), output.resolve()
    if output == root or root in output.parents:
        raise ValueError("Place release artifacts outside the source folder")
    result = audit(root)
    if not result["passed"]:
        raise ValueError("Release audit failed; no archive was created")
    if output.exists():
        raise FileExistsError("Do not overwrite an existing release archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in FILES:
            path = root / name
            if path.is_symlink() or root not in path.resolve().parents:
                raise ValueError("Release source escaped the repository")
            archive.write(path, "windows-network-workbench/" + name)
    with zipfile.ZipFile(output) as archive:
        if sorted(archive.namelist()) != sorted("windows-network-workbench/" + name for name in FILES):
            raise ValueError("Archive allowlist verification failed")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(digest + "  " + output.name + "\n", encoding="ascii")
    return {"files": len(FILES), "sha256": digest, "runtime_included": False}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root")
    parser.add_argument("output")
    args = parser.parse_args()
    print(json.dumps(package(Path(args.root), Path(args.output)), indent=2))
