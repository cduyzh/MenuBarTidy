#!/usr/bin/env python3
"""仅安装本产品到 /Applications；签名与来源核验后原子切换，异常时恢复。"""
import argparse
import ctypes
import datetime
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile

import app_common as common


def atomic_swap(first, second):
    # macOS renameatx_np 的 RENAME_SWAP 在同一卷内原子交换两个目录。
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    function = libc.renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(-2, os.fsencode(first), -2, os.fsencode(second), 0x00000002) != 0:
        raise OSError(ctypes.get_errno(), "应用原子切换失败")


def register(app, unregister=False, required=True):
    return subprocess.run([common.LSREGISTER, "-u" if unregister else "-f", str(app)],
                          check=required, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=common.BUILT_APP, help="待安装的本产品应用包")
    parser.add_argument("--quit-running", action="store_true", help="精确核对可执行路径后向本产品进程发送 SIGTERM；不强杀")
    parser.add_argument("--dry-run", action="store_true", help="仅检查，不停止进程、不安装、不注册")
    args = parser.parse_args()
    source = args.app.absolute()
    if source.is_symlink():
        raise ValueError("安装源不可为符号链接")
    source = source.resolve()
    target = common.INSTALLED_APP
    if source == target:
        raise ValueError("请从 .build.noindex 中的构建应用安装")
    info, metadata = common.check_bundle(source)
    common.check_existing_product(target)
    if not os.access(target.parent, os.W_OK):
        raise ValueError("/Applications 不可写，请使用具有该目录写入权限的本机账户")
    print(f'待安装：{source}\n正式入口：{target}\n版本：{info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]})', flush=True)
    instances = common.running_instances()
    if args.dry_run:
        for pid, _, path in instances:
            print(f"运行中：PID {pid} · {path}")
        print("预演完成，未停止进程或修改应用。")
        return
    # 校验全部通过后，只有显式参数允许停止本产品。
    if args.quit_running:
        common.quit_running()
    else:
        common.require_stopped()

    workspace = pathlib.Path(tempfile.mkdtemp(prefix=".cduyzh-process-install.noindex.", dir=target.parent))
    (workspace / ".metadata_never_index").touch()
    staged = workspace / target.name
    switched = False
    had_previous = target.exists()
    committed = False
    backup_dir = None

    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"收到信号 {signum}")

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        subprocess.run(["/usr/bin/ditto", str(source), str(staged)], check=True)
        common.check_bundle(staged)
        common.check_existing_product(target)
        common.require_stopped()
        if had_previous:
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_dir = pathlib.Path.home() / "Library/Application Support" / common.APP_NAME / "InstallBackups" / f"{stamp}-{os.getpid()}"
            backup_dir.mkdir(parents=True, exist_ok=False)
            archive = backup_dir / "previous-app.zip"
            subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(target), str(archive)], check=True)
            (backup_dir / "SHA256SUMS.txt").write_text(f"{common.sha256_file(archive)}  {archive.name}\n")
            (backup_dir / "restore.txt").write_text(
                "旧应用已压缩为 previous-app.zip，不作为 Spotlight 应用副本。\n"
                "恢复时先退出本产品，将当前 /Applications/cduyzhProcessTool.app 移到其他目录，\n"
                "再执行 ditto -x -k previous-app.zip /Applications，并重新注册 LaunchServices。\n",
                encoding="utf-8")
        # 暂存校验与备份期间若用户重新启动应用，则拒绝切换。
        common.require_stopped()
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        try:
            if had_previous:
                atomic_swap(staged, target)
            else:
                os.rename(staged, target)
            switched = True
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        common.check_bundle(target)
        # 只撤销本轮安装源的注册；正式入口固定为 /Applications。
        register(source, unregister=True, required=False)
        register(target)
        subprocess.run(["/usr/bin/mdimport", str(target)], check=False, capture_output=True)
        committed = True
        print(f"安装完成：{target}")
        print(f'版本：{info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]}) · 来源 {metadata["sourceHash"][:12]}')
        if backup_dir:
            print(f"旧版本压缩备份：{backup_dir}")
        print(f"启动：open '{target}'")
    finally:
        # 回滚阶段不再接受第二次中断，保证旧目录和清理步骤能完成。
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if switched and not committed:
            if args.quit_running:
                common.quit_running([target])
            else:
                try:
                    common.require_stopped([target])
                except ValueError:
                    print(f"回滚暂停：安装后的应用被另行启动，请先退出；旧应用仍保存在 {staged}，压缩备份为 {backup_dir}。", flush=True)
                    raise
            if had_previous:
                atomic_swap(staged, target)
            elif target.exists():
                os.rename(target, staged)
            register(target, required=False) if target.exists() else register(target, unregister=True, required=False)
            print("安装未完成，已恢复安装前状态。", flush=True)
        shutil.rmtree(workspace, ignore_errors=False)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        raise SystemExit(f"安装中止：{error}")
