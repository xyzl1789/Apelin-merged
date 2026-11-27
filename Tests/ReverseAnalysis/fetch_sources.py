#!/usr/bin/env python3
"""下载并校验逆向分析实验依赖，只写入项目 build 缓存。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tarfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "build" / "reverse-analysis"
ARTIFACTS = [
    ("radare2-6.2.6.tar.xz", "radareorg/radare2", "1a0e09c0f781337ae8cd3f4a1d295ac64344d0b019031f75755dbc8e246b9f8a", 46826944),
    ("r2ghidra-6.2.6.tar.xz", "radareorg/r2ghidra", "4fe9aeb4ab226b6b552b5d61a284f9b6b08b20579bbac1bcaa6785bfe957991f", 4017168),
    ("r2ghidra_sleigh-6.2.6.zip", "radareorg/r2ghidra", "dc824a89a0cdb589407932875da1e3e5eb86f8f8fa37e01920489a73b73efc2c", 10385502),
    ("patch_ng-1.19.1.tar.gz", "https://files.pythonhosted.org/packages/da/b6/8ea8095f964f93567bbe28709298b30104ad418b50d4217538387bf48f7d/patch_ng-1.19.1.tar.gz", "036a3cc00134ec53f37e92333958ee75e117f2e62a5ec2b85c7122e5e815c29e", 18525),
]


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inside(root, name):
    target = root / name
    if name.startswith("/") or ".." in Path(name).parts:
        raise RuntimeError("归档含越界路径")
    if not target.resolve().is_relative_to(root.resolve()):
        raise RuntimeError("归档路径经过越界链接")
    return target


def unpack(archive, target):
    marker = target / ".verified-sha256"
    expected = digest(archive)
    if target.exists():
        if marker.is_file() and marker.read_text().strip() == expected:
            return
        raise RuntimeError(f"保留未确认的已有解包目录：{target.name}")
    target.mkdir(parents=True)
    total = 0
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                dest = inside(target, item.filename)
                total += item.file_size
                if total > 1024 ** 3:
                    raise RuntimeError("归档解包超过实验限制")
                if stat.S_ISLNK(item.external_attr >> 16):
                    raise RuntimeError("ZIP 不接受符号链接")
                if item.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(item) as src, dest.open("xb") as out:
                        shutil.copyfileobj(src, out)
    else:
        with tarfile.open(archive) as t:
            links = []
            for item in t:
                dest = inside(target, item.name)
                total += item.size
                if total > 1024 ** 3:
                    raise RuntimeError("归档解包超过实验限制")
                if item.isdir():
                    dest.mkdir(parents=True, exist_ok=True)
                elif item.isfile():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with t.extractfile(item) as src, dest.open("xb") as out:
                        shutil.copyfileobj(src, out)
                    dest.chmod(item.mode & 0o777)
                elif item.issym() or item.islnk():
                    links.append((item, dest))
                else:
                    raise RuntimeError("归档含非普通文件")
            for item, dest in links:
                dest.parent.mkdir(parents=True, exist_ok=True)
                link = (dest.parent / item.linkname) if item.issym() else (target / item.linkname)
                if Path(item.linkname).is_absolute() or not link.resolve().is_relative_to(target.resolve()):
                    raise RuntimeError("归档链接越界")
                if item.issym():
                    dest.symlink_to(item.linkname)
                else:
                    os.link(link, dest)
    marker.write_text(expected + "\n")


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    records = []
    for name, repo, expected, size in ARTIFACTS:
        archive = CACHE / name
        url = repo if repo.startswith("https://") else f"https://github.com/{repo}/releases/download/6.2.6/{name}"
        if not archive.exists():
            partial = archive.with_suffix(archive.suffix + ".part")
            for attempt in range(3):
                try:
                    request = urllib.request.Request(url, headers={"User-Agent": "ReverseAnalysisExperiment/1"})
                    with urllib.request.urlopen(request, timeout=90) as src, partial.open("wb") as out:
                        shutil.copyfileobj(src, out, length=1024 * 1024)
                    if partial.stat().st_size != size or digest(partial) != expected:
                        raise RuntimeError("下载大小或 SHA-256 与官方发布元数据不符")
                    partial.rename(archive)
                    break
                except Exception:
                    if attempt == 2:
                        raise
                    time.sleep(2 ** attempt)
        if archive.stat().st_size != size or digest(archive) != expected:
            raise RuntimeError(f"已有归档校验失败，未覆盖：{name}")
        target = CACHE / (name.removesuffix(".tar.xz").removesuffix(".tar.gz").removesuffix(".zip") + "-source")
        unpack(archive, target)
        records.append({"name": name, "url": url, "sha256": expected, "bytes": size, "directory": str(target.relative_to(ROOT))})
        print(f"已校验并解包：{name}", flush=True)
    (CACHE / "sources.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
