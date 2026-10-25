#!/usr/bin/env python3
"""以 Info.plist 为版本真值，校验历史记录并为应用写入实际构建来源。"""
import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
HISTORY_PATH = ROOT / "Resources/ReleaseHistory.json"
BUNDLE_ID = "com.cduyzh.menu-bar"
APP_NAME = "cduyzhMenuBar"


def read_info(path=None):
    with (path or ROOT / "Info.plist").open("rb") as handle:
        return plistlib.load(handle)


def release_history():
    document = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
    releases = document.get("releases", [])
    if not releases:
        raise ValueError("更新历史不能为空")
    seen = set()
    previous_build = float("inf")
    for release in releases:
        if not re.fullmatch(r"\d+\.\d+\.\d+", release["version"]):
            raise ValueError("版本号须采用 major.minor.patch")
        if not re.fullmatch(r"[1-9]\d*", release["build"]):
            raise ValueError("构建号须为正整数字符串")
        identity = (release["version"], release["build"])
        if identity in seen or int(release["build"]) >= previous_build:
            raise ValueError("历史记录须按构建号倒序且不得重复")
        seen.add(identity)
        previous_build = int(release["build"])
        datetime.date.fromisoformat(release["date"])
        for key in ["title", "summary"]:
            if not release[key].strip():
                raise ValueError(f"更新记录缺少 {key}")
        if not release["highlights"] or not all(isinstance(item, str) and item.strip() for item in release["highlights"]):
            raise ValueError("更新内容不能为空")
        if not all(isinstance(item, str) and item.strip() for item in release.get("notes", [])):
            raise ValueError("使用说明须为非空字符串列表")
    return document


def changelog(document):
    lines = ["# 版本记录", "", "由 Resources/ReleaseHistory.json 生成；根目录 Info.plist 是当前版本号与构建号的唯一真值。记录日期不等同于远端发布日期。", ""]
    for release in document["releases"]:
        lines += [f'## {release["version"]}（构建 {release["build"]}） · {release["date"]}', "", release["title"], "", release["summary"], ""]
        lines += [f"- {item}" for item in release["highlights"]]
        if release.get("notes"):
            lines += ["", "使用说明：", ""] + [f"- {item}" for item in release["notes"]]
        lines.append("")
    return "\n".join(lines)


def validate_repository(write_changelog=False):
    info = read_info()
    document = release_history()
    latest = document["releases"][0]
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != APP_NAME:
        raise ValueError("Info.plist 应用标识或可执行文件名不正确")
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (latest["version"], latest["build"]):
        raise ValueError("Info.plist 版本与首条历史记录不一致")
    path = ROOT / "CHANGELOG.md"
    expected = changelog(document)
    if write_changelog:
        path.write_text(expected, encoding="utf-8")
    elif not path.is_file() or path.read_text(encoding="utf-8") != expected:
        raise ValueError("CHANGELOG.md 不一致，请运行 python3 scripts/release_metadata.py --write-changelog")
    return info, document


def source_hash():
    # 仅纳入构建输入和本地发行脚本；忽略输出、缓存及 .git 状态。
    paths = [ROOT / "Info.plist", ROOT / "Package.swift", ROOT / "build_app.sh"]
    for directory in ["Sources", "Resources", "scripts"]:
        paths += [path for path in (ROOT / directory).rglob("*") if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc" and path.name != ".DS_Store"]
    digest = hashlib.sha256()
    for path in sorted(set(paths)):
        relative = path.relative_to(ROOT).as_posix().encode()
        content = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def source_revision():
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True)
    if result.returncode != 0:
        return "unversioned"
    revision = result.stdout.strip()
    status = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, text=True, capture_output=True)
    return revision + ("-modified" if status.stdout.strip() else "")


def stamp_bundle(bundle, info, document, expected_hash=None):
    info_path = bundle / "Contents/Info.plist"
    bundled = read_info(info_path)
    keys = ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"]
    if any(bundled.get(key) != info.get(key) for key in keys):
        raise ValueError("待打包应用的标识或版本与 Info.plist 不一致")
    latest = document["releases"][0]
    build_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    revision, digest = source_revision(), source_hash()
    if expected_hash is not None and expected_hash != digest:
        raise ValueError("编译期间源文件已变化，请在修改完成后重新构建")
    bundled.update(CDUYZHBuildDate=build_date, CDUYZHReleaseDate=latest["date"], CDUYZHSourceRevision=revision, CDUYZHSourceHash=digest)
    with info_path.open("wb") as handle:
        plistlib.dump(bundled, handle, sort_keys=False)
    resources = bundle / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "ReleaseHistory.json").write_text(HISTORY_PATH.read_text(encoding="utf-8"), encoding="utf-8")
    metadata = {
        "name": APP_NAME, "bundleIdentifier": BUNDLE_ID,
        "version": latest["version"], "build": latest["build"],
        "releaseDate": latest["date"], "buildDate": build_date,
        "sourceRevision": revision, "sourceHash": digest,
        "signing": "ad-hoc", "notarized": False,
        "remoteUpdatesConfigured": False,
    }
    (resources / "build-info.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-changelog", action="store_true")
    parser.add_argument("--stamp-bundle", type=pathlib.Path)
    parser.add_argument("--source-hash", action="store_true")
    parser.add_argument("--expected-source-hash")
    args = parser.parse_args()
    info, document = validate_repository(args.write_changelog)
    if args.source_hash:
        print(source_hash())
        return
    if args.stamp_bundle:
        stamp_bundle(args.stamp_bundle.resolve(), info, document, args.expected_source_hash)
    print(f'版本记录一致：{info["CFBundleShortVersionString"]}（构建 {info["CFBundleVersion"]}）')


if __name__ == "__main__":
    main()
