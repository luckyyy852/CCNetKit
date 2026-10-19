"""Single platform entry. Installation never starts a proxy or changes networking."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True

SOURCE = Path(__file__).resolve().parents[1]


def plan(system=None):
    system = system or platform.system()
    if system == "Windows":
        return {"platform": "Windows", "installer": "Install-Workbench.ps1", "interface": "WinForms"}
    if system == "Darwin":
        return {"platform": "macOS", "installer": "local-copy", "interface": "loopback-web"}
    raise ValueError("This skill supports Windows and macOS only")


def install_mac(root, settings):
    sys.path.insert(0, str(SOURCE / "assets/runtime"))
    import mac_workbench as runtime
    root = Path(root).expanduser().absolute()
    settings = Path(settings).expanduser().absolute()
    runtime.external_path(root, SOURCE, exists=False)
    if root.exists() or not root.parent.is_dir():
        raise ValueError("Choose a new installation directory with an existing parent")
    runtime.inspect_settings(settings, SOURCE)
    root.mkdir(mode=0o700)
    try:
        (root / "bin").mkdir(mode=0o700)
        (root / "data").mkdir(mode=0o700)
        shutil.copyfile(SOURCE / "assets/runtime/mac_workbench.py", root / "bin/mac_workbench.py")
        shutil.copyfile(SOURCE / "assets/runtime/mac_ui.html", root / "bin/mac_ui.html")
        shutil.copyfile(settings, root / "settings.json")
        os.chmod(root / "settings.json", 0o600)
        runtime.atomic_write(root / "data/routes.json", b'{"SchemaVersion":1,"Profiles":{}}\n')
        launcher = root / "Open Workbench.command"
        launcher.write_text('#!/bin/sh\ncd -- "$(dirname -- "$0")" || exit 1\nexec '
                            + "'" + sys.executable.replace("'", "'\"'\"'") + "'"
                            + ' ./bin/mac_workbench.py --root "$PWD"\n', encoding="utf-8")
        os.chmod(launcher, 0o700)
    except Exception:
        # Only the new directory created by this invocation is removed.
        shutil.rmtree(root)
        raise
    return {"installed": True, "platform": "macOS", "network_changed": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("detect", "install"))
    parser.add_argument("--root")
    parser.add_argument("--settings")
    args = parser.parse_args()
    selected = plan()
    if args.action == "detect":
        print(json.dumps(selected))
        return 0
    if not args.root or not args.settings:
        parser.error("install requires --root and --settings")
    if selected["platform"] == "Windows":
        # Keep the original Windows installer and elevation behavior unchanged.
        return subprocess.call(["powershell.exe", "-NoProfile", "-File",
                                str(SOURCE / "scripts/Install-Workbench.ps1"),
                                "-InstallRoot", args.root, "-SettingsPath", args.settings])
    if os.geteuid() == 0:
        raise ValueError("Run the workbench installer as your normal user, without sudo")
    print(json.dumps(install_mac(args.root, args.settings)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError):
        print("Installation refused. Check private settings, permissions and target paths.", file=sys.stderr)
        raise SystemExit(1)
