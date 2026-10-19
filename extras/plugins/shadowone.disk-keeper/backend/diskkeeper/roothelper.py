"""Client side of the root helper: install checks and the single pkexec call per job."""

import hashlib
import json
import os
import re
import shlex
import stat
import subprocess

from . import paths

INSTALLED = "/usr/local/libexec/diskkeeper-root"
POLICY = "/usr/share/polkit-1/actions/io.github.shadowone.diskkeeper.policy"


def plugin_dir():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def bundled():
    return os.path.join(plugin_dir(), "root", "diskkeeper-root")


def _sha256(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def setup_command():
    script = os.path.join(plugin_dir(), "root", "install.sh")
    short = paths.contract(script)
    if not re.fullmatch(r"[\w@%+=:,./~-]+", short):
        short = shlex.quote(script)
    return "sudo bash " + short


def status():
    try:
        st = os.stat(INSTALLED)
        installed = os.path.isfile(POLICY) and stat.S_ISREG(st.st_mode)
        safe = st.st_uid == 0 and not (st.st_mode & (stat.S_IWGRP | stat.S_IWOTH))
    except OSError:
        installed, safe = False, False
    up_to_date = installed and _sha256(INSTALLED) == _sha256(bundled())
    return {"installed": installed, "upToDate": bool(up_to_date), "rootOwned": safe,
            "path": INSTALLED, "setupCommand": setup_command()}


def run(tokens, dry_run=False, timeout=1800):
    """Run all root tokens in one pkexec call. Returns {auth, ok, verbs, message}."""
    st = status()
    if not st["installed"] or not st["rootOwned"]:
        return {"auth": "missing", "ok": False, "verbs": [], "message": "Root helper not installed: " + st["setupCommand"]}
    if not st["upToDate"]:
        return {"auth": "outdated", "ok": False, "verbs": [], "message": "Root helper is outdated: " + st["setupCommand"]}
    argv = ["/usr/bin/pkexec", INSTALLED] + (["--dry-run"] if dry_run else []) + ["--json"] + list(tokens)
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, errors="replace", timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return {"auth": "error", "ok": False, "verbs": [], "message": "Root helper timed out"}
    if r.returncode in (126, 127):
        return {"auth": "cancelled", "ok": False, "verbs": [], "message": "Authentication cancelled"}
    data = None
    for line in reversed(r.stdout.strip().splitlines()):
        try:
            data = json.loads(line)
            break
        except ValueError:
            continue
    if not isinstance(data, dict):
        return {"auth": "error", "ok": False, "verbs": [], "message": (r.stderr or "No output from helper").strip()[-300:]}
    return {"auth": "ok", "ok": bool(data.get("ok")), "verbs": data.get("verbs") or [],
            "message": data.get("error") or ""}
