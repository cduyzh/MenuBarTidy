#!/usr/bin/env python3
"""复用已构建且验签通过的应用，仅生成本地发行工件。"""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

import app_common as common


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=common.BUILT_APP)
    args = parser.parse_args()
    source = args.app.resolve()
    info, build_info = common.check_bundle(source)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    output = common.ROOT / "dist" / f"v{version}-build{build}"
    if output.exists():
        raise ValueError(f"发行目录已存在，拒绝覆盖：{output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    workspace = pathlib.Path(tempfile.mkdtemp(prefix=".package.noindex.", dir=output.parent))
    try:
        archive = workspace / f"{common.APP_NAME}-{version}-build{build}.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(source), str(archive)], check=True)
        digest = common.sha256_file(archive)
        shutil.copy2(common.ROOT / "CHANGELOG.md", workspace / "CHANGELOG.md")
        shutil.copy2(source / "Contents/Resources/build-info.json", workspace / "build-info.json")
        record = common.release.release_history()["releases"][0]
        metadata = dict(build_info, archive=archive.name, sha256=digest, publication="local", title=record["title"], highlights=record["highlights"])
        (workspace / "release.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        entries = sorted(path for path in workspace.iterdir() if path.is_file())
        (workspace / "SHA256SUMS.txt").write_text("".join(f"{common.sha256_file(path)}  {path.name}\n" for path in entries), encoding="utf-8")
        workspace.rename(output)
        print(f"本地发行包：{output / archive.name}\nSHA-256：{digest}")
        print("已生成发行元数据与校验和，未执行上传、创建远端发布或 Git 操作。")
    finally:
        if workspace.exists():
            shutil.rmtree(workspace)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"打包中止：{error}")
