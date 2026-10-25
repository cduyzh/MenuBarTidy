#!/usr/bin/env python3
"""校验后原子替换本项目构建产物，不影响 /Applications 正式安装。"""
import pathlib
import os
import shutil
import sys

import app_common as common
from install_local import atomic_swap

source = pathlib.Path(sys.argv[1]).resolve()
target = common.BUILT_APP
common.check_bundle(source)
common.check_existing_product(target)
common.require_stopped([target])
if target.exists():
    atomic_swap(source, target)
    shutil.rmtree(source)
else:
    os.rename(source, target)
print(f"构建产物校验通过：{target}")
