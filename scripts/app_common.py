#!/usr/bin/env python3
"""构建、安装和发行共用的应用身份及运行实例检查。"""
import ctypes
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

import release_metadata as release

ROOT = release.ROOT
APP_NAME = release.APP_NAME
BUNDLE_ID = release.BUNDLE_ID
BUILT_APP = ROOT / ".build.noindex" / f"{APP_NAME}.app"
INSTALLED_APP = pathlib.Path("/Applications") / f"{APP_NAME}.app"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def check_bundle(app, require_source=True):
    app = pathlib.Path(app)
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"应用不是普通目录或为符号链接：{app}")
    info, history = release.validate_repository()
    bundled = release.read_info(app / "Contents/Info.plist")
    keys = ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"]
    if any(bundled.get(key) != info.get(key) for key in keys):
        raise ValueError(f"应用标识或版本与当前项目不一致：{app}")
    binary = app / "Contents/MacOS" / APP_NAME
    if not binary.is_file() or binary.is_symlink() or not os.access(binary, os.X_OK):
        raise ValueError(f"应用缺少可执行文件：{binary}")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", f'=identifier "{BUNDLE_ID}"', str(app)], check=True)
    resources = app / "Contents/Resources"
    if json.loads((resources / "ReleaseHistory.json").read_text(encoding="utf-8")) != history:
        raise ValueError("应用内更新历史与当前项目不一致，请重新构建")
    metadata = json.loads((resources / "build-info.json").read_text(encoding="utf-8"))
    checks = {
        "bundleIdentifier": BUNDLE_ID,
        "version": bundled["CFBundleShortVersionString"], "build": bundled["CFBundleVersion"],
        "buildDate": bundled.get("CDUYZHBuildDate"),
        "sourceRevision": bundled.get("CDUYZHSourceRevision"),
        "sourceHash": bundled.get("CDUYZHSourceHash"),
    }
    if any(metadata.get(key) != value for key, value in checks.items()):
        raise ValueError("应用构建元数据与 Info.plist 不一致")
    if not metadata.get("buildDate") or not metadata.get("sourceHash"):
        raise ValueError("应用缺少实际构建时间或来源摘要")
    if require_source and metadata["sourceHash"] != release.source_hash():
        raise ValueError("应用来源摘要与当前源文件不一致，请重新构建")
    return bundled, metadata


def check_existing_product(app):
    """旧版本允许不同版本号，但绝不覆盖其他应用或符号链接。"""
    app = pathlib.Path(app)
    if not app.exists() and not app.is_symlink():
        return
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"拒绝覆盖符号链接或非应用目录：{app}")
    info = release.read_info(app / "Contents/Info.plist")
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != APP_NAME:
        raise ValueError(f"目标属于其他产品，拒绝覆盖：{app}")


_libproc = None


def executable_path(pid):
    global _libproc
    if _libproc is None:
        _libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        _libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        _libproc.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if _libproc.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        return None
    return pathlib.Path(os.fsdecode(buffer.value)).resolve()


def is_product_executable(path):
    if path.name != APP_NAME:
        return False
    # 开发二进制仅认可本项目 .build / .build.noindex 中的精确产品文件。
    for directory in [ROOT / ".build", ROOT / ".build.noindex"]:
        if path.is_relative_to(directory.resolve()):
            return True
    # 任意位置的本产品 .app 副本也须核对完整 Bundle ID 与 executable。
    if path.parent.name == "MacOS" and path.parent.parent.name == "Contents":
        app = path.parent.parent.parent
        if app.suffix.lower() == ".app":
            try:
                info = release.read_info(app / "Contents/Info.plist")
                return info.get("CFBundleIdentifier") == BUNDLE_ID and info.get("CFBundleExecutable") == APP_NAME
            except (OSError, ValueError):
                pass
    return False


def running_instances(exact_apps=None):
    result = subprocess.run(["/bin/ps", "-axo", "pid=,uid="], text=True, capture_output=True, check=True)
    allowed_paths = None
    if exact_apps is not None:
        allowed_paths = {(pathlib.Path(app) / "Contents/MacOS" / APP_NAME).resolve() for app in exact_apps}
    instances = []
    for row in result.stdout.splitlines():
        fields = row.split()
        if len(fields) != 2:
            continue
        pid, uid = map(int, fields)
        if pid == os.getpid():
            continue
        path = executable_path(pid)
        if path and (path in allowed_paths if allowed_paths is not None else is_product_executable(path)):
            instances.append((pid, uid, path))
    return instances


def require_stopped(exact_apps=None):
    instances = running_instances(exact_apps)
    if instances:
        detail = "\n".join(f"  PID {pid} · {path}" for pid, _, path in instances)
        raise ValueError(f"本产品仍在运行，拒绝覆盖。请正常退出，或安装时显式加 --quit-running：\n{detail}")


def quit_running(exact_apps=None):
    instances = running_instances(exact_apps)
    for pid, uid, path in instances:
        if uid != os.getuid():
            raise ValueError(f"本产品由另一用户运行，无法安装：PID {pid}")
        # 信号前再核对路径，避免按进程名称误结束其他产品。
        if executable_path(pid) == path and is_product_executable(path):
            print(f"停止本产品：PID {pid} · {path}", flush=True)
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 15
    while running_instances(exact_apps) and time.monotonic() < deadline:
        time.sleep(0.2)
    require_stopped(exact_apps)


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "check-bundle":
            info, _ = check_bundle(sys.argv[2])
            print(f'应用校验通过：{info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]})')
        elif len(sys.argv) == 3 and sys.argv[1] == "require-stopped":
            require_stopped([sys.argv[2]])
        else:
            raise ValueError("用法：app_common.py check-bundle|require-stopped 应用路径")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
