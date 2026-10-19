"""Browse the largest folders and files in $HOME; move picked ones to the Trash.

Nothing here deletes permanently. Trash is a rename inside @home, so it frees
no space until the Trash is emptied (the Clean up tab offers that).
"""

import os
import stat

from . import fsops, paths

# Relative to $HOME. The folder itself is protected, its contents are not.
PROTECTED_SELF = {"", ".config", ".local", ".local/share", ".local/state", ".cache", "Documents", "Downloads",
                  "Pictures", "Music", "Videos", "Desktop", "Projects", "Work", "Public", "Templates"}
# Relative to $HOME. The folder and everything below it is protected.
PROTECTED_TREE = (".ssh", ".gnupg", ".local/share/keyrings", ".password-store", ".pki", ".config/omarchy",
                  ".local/share/Trash", ".local/state/diskkeeper", ".config/diskkeeper")


def protection(rel):
    if rel in PROTECTED_SELF:
        return "system-folder"
    for tree in PROTECTED_TREE:
        if rel == tree or rel.startswith(tree + "/"):
            return "protected"
    return None


def explore(cfg, rel="", limit=200):
    if rel and not fsops.valid_rel(rel):
        return {"error": "invalid path"}
    base = os.path.join(paths.home(), rel) if rel else paths.home()
    st = fsops.lstat(base) if rel else os.lstat(base)
    if st is None or not stat.S_ISDIR(st.st_mode):
        return {"error": "not a folder"}
    keep = paths.keep_paths(cfg)
    sizes = fsops.du_children(base)
    children = []
    for name, cst in fsops.list_children(base):
        crel = (rel + "/" + name) if rel else name
        abs_path = os.path.join(base, name)
        if stat.S_ISLNK(cst.st_mode):
            kind = "link"
        elif stat.S_ISDIR(cst.st_mode):
            kind = "dir"
        else:
            kind = "file"
        other_fs = kind == "dir" and cst.st_dev != st.st_dev
        prot = protection(crel)
        kept = paths.is_kept(abs_path, keep)
        ok_name = fsops.round_trips(name)
        children.append({
            "name": fsops.display_name(name), "rel": crel if ok_name else None, "type": kind,
            "bytes": 0 if other_fs else sizes.get(name, cst.st_blocks * 512),
            "mtime": int(cst.st_mtime), "protected": prot, "kept": kept, "otherFs": other_fs,
            "actionable": ok_name and prot is None and not kept and not other_fs,
            "browsable": ok_name and kind == "dir" and not other_fs,
            "confirm": "extra" if (name.startswith(".") and "/" not in crel) else "normal",
        })
    children.sort(key=lambda c: -c["bytes"])
    total = sum(c["bytes"] for c in children)
    parent = None
    if rel:
        parent = os.path.dirname(rel)
    return {"path": rel, "display": paths.contract(base), "parent": parent, "total": total,
            "count": len(children), "children": children[:limit], "truncated": max(0, len(children) - limit)}


def trash(cfg, rels, ctx):
    keep = paths.keep_paths(cfg)
    results = []
    for rel in rels:
        if not fsops.valid_rel(rel):
            results.append({"rel": rel, "status": "skipped", "reason": "invalid-path"})
            continue
        prot = protection(rel)
        abs_path = os.path.join(paths.home(), rel)
        if prot:
            results.append({"rel": rel, "status": "skipped", "reason": prot})
            continue
        if paths.is_kept(abs_path, keep):
            results.append({"rel": rel, "status": "skipped", "reason": "kept"})
            continue
        st = fsops.lstat(abs_path)
        if st is None:
            results.append({"rel": rel, "status": "skipped", "reason": "gone"})
            continue
        r = ctx.run(["gio", "trash", "--", abs_path], timeout=300)
        if r.returncode == 0:
            results.append({"rel": rel, "status": "done"})
        else:
            results.append({"rel": rel, "status": "failed", "reason": "tool-error", "detail": r.stderr.strip()[-200:]})
    return results


def keep_change(cfg, action, rel):
    if not fsops.valid_rel(rel):
        return False, "invalid path"
    entry = paths.contract(os.path.join(paths.home(), rel))
    keep = list(cfg.get("keep", []))
    norm = {os.path.normpath(paths.expand(k)): k for k in keep}
    target = os.path.normpath(os.path.join(paths.home(), rel))
    if action == "add":
        if target not in norm:
            keep.append(entry)
    elif action == "remove":
        keep = [k for k in keep if os.path.normpath(paths.expand(k)) != target]
    else:
        return False, "unknown action"
    cfg = dict(cfg)
    cfg["keep"] = keep
    paths.save_config(cfg)
    return True, entry
