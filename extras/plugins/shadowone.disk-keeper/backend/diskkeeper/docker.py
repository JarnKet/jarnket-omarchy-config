"""Docker categories.

Deliberately absent: `docker container prune` and `docker volume prune`.
Stopped containers keep their databases in anonymous volumes; pruning the
containers would orphan those volumes and the next volume prune would
delete the data. Volumes are only removed one by one, by name, after the
user picked them.
"""

import json
import re

from . import registry

_SI = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
       "KIB": 1024, "MIB": 1024 ** 2, "GIB": 1024 ** 3, "TIB": 1024 ** 4}


def parse_size(text):
    """Docker's human sizes ("2.231GB", "33.85MB", "1.2kB", "0B", "N/A") to bytes."""
    m = re.match(r"\s*([0-9.]+)\s*([A-Za-z]+)", str(text or ""))
    if not m:
        return 0
    unit = m.group(2).upper()
    try:
        return int(float(m.group(1)) * _SI.get(unit, 0))
    except ValueError:
        return 0


def _df(ctx):
    """`docker system df -v` once per context; None when the daemon is unreachable."""
    if "docker-df" not in ctx.memo:
        data = None
        r = ctx.run(["docker", "system", "df", "-v", "--format", "json"], timeout=60)
        if r.returncode == 0:
            try:
                data = json.loads(r.stdout)
            except ValueError:
                data = None
        ctx.memo["docker-df"] = data
    return ctx.memo["docker-df"]


def _summary(ctx):
    if "docker-sum" not in ctx.memo:
        rows = {}
        r = ctx.run(["docker", "system", "df", "--format", "json"], timeout=60)
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                try:
                    row = json.loads(line)
                    rows[row.get("Type")] = row
                except ValueError:
                    continue
        ctx.memo["docker-sum"] = rows
    return ctx.memo["docker-sum"]


class DockerCategory(registry.Category):
    group = "docker"
    privilege = "docker"
    frees_when = "after-snapshots"
    estimate_kind = "tool"
    command = ()

    def available(self, ctx):
        return _df(ctx) is not None

    def estimate(self, ctx):
        return 0

    def scan(self, ctx):
        out = self.describe()
        if not self.available(ctx):
            out.update(available=False, bytes=0, items=[], blocked=None, note="Docker is not running")
            return out
        out.update(available=True, bytes=self.estimate(ctx), items=[], blocked=None, note=self.note(ctx))
        return out

    def clean(self, ctx, keys, scan_items):
        if not self.available(ctx):
            return [registry.result(self.id, "skipped", "unavailable", "Docker is not running")]
        if ctx.dry_run:
            return [registry.result(self.id, "done", detail="dry run")]
        r = ctx.run(list(self.command), timeout=900)
        if r.returncode != 0:
            return [registry.result(self.id, "failed", "tool-error", (r.stderr or r.stdout).strip()[-300:])]
        last = [l for l in r.stdout.strip().splitlines() if l.strip()]
        return [registry.result(self.id, "done", detail=last[-1] if last else "")]


class BuildCache(DockerCategory):
    id = "docker-build-cache"
    title = "Docker build cache"
    description = "Layers kept to speed up `docker build`. The next build is slower once."
    command = ("docker", "builder", "prune", "-f")

    def estimate(self, ctx):
        return parse_size(_summary(ctx).get("Build Cache", {}).get("Reclaimable"))


def _images(ctx):
    data = _df(ctx) or {}
    return data.get("Images") or []


def _is_dangling(img):
    return img.get("Repository") in ("<none>", "") and img.get("Tag") in ("<none>", "")


class DanglingImages(DockerCategory):
    id = "docker-dangling-images"
    title = "Dangling Docker images"
    description = "Untagged leftovers of rebuilt images."
    command = ("docker", "image", "prune", "-f")

    def estimate(self, ctx):
        return sum(parse_size(i.get("UniqueSize") or i.get("Size")) for i in _images(ctx)
                   if _is_dangling(i) and str(i.get("Containers", "0")) == "0")


class UnusedImages(DockerCategory):
    id = "docker-unused-images"
    title = "Unused Docker images"
    description = "Images that no container, running or stopped, uses. They must be pulled or built again."
    risk = "redownload"
    default_selected = False
    command = ("docker", "image", "prune", "-a", "-f")

    def note(self, ctx):
        names = ["%s:%s" % (i.get("Repository"), i.get("Tag")) for i in _images(ctx)
                 if not _is_dangling(i) and str(i.get("Containers", "0")) == "0"]
        return ", ".join(n.rsplit("/", 1)[-1] for n in names[:4]) + (" …" if len(names) > 4 else "") if names else None

    def estimate(self, ctx):
        return sum(parse_size(i.get("UniqueSize") or i.get("Size")) for i in _images(ctx)
                   if not _is_dangling(i) and str(i.get("Containers", "0")) == "0")


class DanglingVolumes(DockerCategory):
    id = "docker-volumes"
    title = "Unused Docker volumes"
    description = "Volumes no container is attached to. They can hold database files: check before removing."
    risk = "data"
    itemized = True
    confirm = "extra"
    default_selected = False

    def _dangling(self, ctx):
        vols = [v for v in ((_df(ctx) or {}).get("Volumes") or []) if str(v.get("Links", "")) == "0"]
        created = {}
        if vols:
            r = ctx.run(["docker", "volume", "inspect", "--format", "{{json .}}"] + [v["Name"] for v in vols], timeout=60)
            for line in r.stdout.splitlines():
                try:
                    info = json.loads(line)
                    created[info.get("Name")] = (info.get("CreatedAt") or "")[:10]
                except ValueError:
                    continue
        return vols, created

    def scan(self, ctx):
        out = self.describe()
        if not self.available(ctx):
            out.update(available=False, bytes=0, items=[], blocked=None, note="Docker is not running")
            return out
        vols, created = self._dangling(ctx)
        items = []
        for v in vols:
            name = v.get("Name", "")
            anon = "com.docker.volume.anonymous" in (v.get("Labels") or "")
            label = (name[:12] + "…") if anon and len(name) > 16 else name
            detail = ("anonymous" if anon else "named") + (" · created " + created[name] if created.get(name) else "")
            items.append({"key": name, "label": label, "detail": detail, "bytes": parse_size(v.get("Size")),
                          "mtime": 0, "id": None, "actionable": True, "blocked": None, "selected": False})
        items.sort(key=lambda i: -i["bytes"])
        out.update(available=True, bytes=sum(i["bytes"] for i in items), items=items, blocked=None, note=None)
        return out

    def clean(self, ctx, keys, scan_items):
        if not self.available(ctx):
            return [registry.result(self.id, "skipped", "unavailable", "Docker is not running")]
        vols, _ = self._dangling(ctx)
        fresh = {v.get("Name") for v in vols}
        wanted = keys or []
        results = []
        for key in wanted:
            target = self.target(key)
            if key not in fresh or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", key or ""):
                results.append(registry.result(target, "skipped", "not-a-candidate", "No longer unused"))
                continue
            if ctx.dry_run:
                results.append(registry.result(target, "done", detail="dry run"))
                continue
            r = ctx.run(["docker", "volume", "rm", "--", key], timeout=120)
            if r.returncode == 0:
                results.append(registry.result(target, "done", bytes_=scan_items.get(key, {}).get("bytes")))
            else:
                results.append(registry.result(target, "failed", "tool-error", r.stderr.strip()[-200:]))
        return results
