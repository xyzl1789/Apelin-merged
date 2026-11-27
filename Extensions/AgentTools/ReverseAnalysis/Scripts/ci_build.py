#!/usr/bin/env python3
"""macOS 交叉编译检查：不执行 iOS 程序，不生成或安装软件包。"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

from build_support import (ROOT, EXT, CACHE, LOCK, archives, build_engine,
                           compile_runtime, check_binary, is_ios_header, sha, tool_path)
from build_package import notices, source_archive

NAMES = ('xyzl-reverse-analysis', 'xyzl-reverse-worker')


def finalize_runtime(runtime):
    # 与发行配方一致地移除对象来源调试符号；strip 后必须重新签名。
    for name in NAMES:
        path = runtime / name
        subprocess.run(['strip', '-x', tool_path(path)], check=True)
        subprocess.run(['ldid', '-S' + str(EXT / 'Packaging/entitlements.plist'), str(path)], check=True)


def verify_runtime(runtime, arch):
    for name in NAMES:
        check_binary(runtime / name, [arch])
    index = json.loads((runtime / 'data-sha256.json').read_text())
    actual = {p.name: sha(p) for p in (runtime / 'sleigh').iterdir() if p.is_file()}
    if len(index) < 8 or actual != index:
        raise RuntimeError('语言数据与摘要清单不符')
    return {'architectures': [arch], 'ios_platform_checked': True,
            'system_dependencies_only': True, 'entitlements_checked': True,
            'private_paths_absent': True, 'language_files_checked': len(index),
            'ios_binaries_executed': False, 'device_acceptance': False}


def verify_host_generator(r2):
    generator = r2 / 'subprojects/sdb/sdb'
    headers = subprocess.check_output(['otool', '-l', str(generator)]).decode()
    macos = (re.search(r'^\s*platform\s+(?:1|MACOS)\s*$', headers, re.MULTILINE)
             or 'LC_VERSION_MIN_MACOSX' in headers)
    if not macos or is_ios_header(headers):
        raise RuntimeError('sdb 生成器不是 macOS 宿主程序')
    return {'sdb_platform': 'macOS', 'separate_from_ios_runtime': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', required=True, choices=('arm64', 'arm64e'))
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    if sys.platform != 'darwin' or not shutil.which('xcrun'):
        raise RuntimeError('交叉编译检查只在具备 Xcode 的 macOS 运行')
    for name in ('clang', 'ar', 'make', 'lipo', 'otool', 'ldid', 'strip'):
        if not shutil.which(name):
            raise RuntimeError('交叉编译缺少工具：' + name)
    os.environ['APELIN_PROJECT_ROOT'] = str(ROOT)
    os.environ['RA_CROSS_COMPILE'] = '1'
    os.environ['SDKROOT'] = subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-path']).decode().strip()
    os.environ['RA_HOST_SDKROOT'] = subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path']).decode().strip()
    # CI 与本机发行对象分开，构建配方改变时仍由内容摘要拒绝混用。
    os.environ.setdefault('RA_BUILD_TAG', 'ci-v1')
    archives()
    base, r2, ghidra, sleigh, env = build_engine(args.arch, args.jobs)
    host_report = verify_host_generator(r2)
    runtime = base / 'runtime'
    compile_runtime(args.arch, runtime, r2, ghidra, sleigh, env)
    finalize_runtime(runtime)
    report = {**verify_runtime(runtime, args.arch), 'host_generator': host_report,
              'packaged': False, 'installed': False}
    output = CACHE / 'ci-artifacts' / args.arch
    if output.exists():
        raise RuntimeError('CI 产物目录已经存在，保留现场而不是覆盖')
    output.mkdir(parents=True)
    for name in NAMES:
        shutil.copyfile(runtime / name, output / name)
        (output / name).chmod(0o755)
    shutil.copytree(runtime / 'sleigh', output / 'sleigh')
    shutil.copyfile(runtime / 'data-sha256.json', output / 'data-sha256.json')
    shutil.copyfile(EXT / 'Descriptors.json', output / 'Descriptors.json')
    # 即使只是 CI 产物，也同时提供静态工作进程的完整对应源码与许可。
    source_archive(output / 'corresponding-source.tar.gz')
    notices(r2, ghidra, base / 'deps' / LOCK[3]['directory'] / LOCK[3]['root'], output / 'licenses')
    (output / 'README.txt').write_text(
        '这是单架构 iOS 交叉编译检查产物，不是可安装软件包。\n'
        '未在 macOS 上执行这些 iOS 程序，也未完成安装或设备功能验收。\n'
        '完整对应源码见 corresponding-source.tar.gz，各上游许可见 licenses/。\n')
    report['files'] = {p.relative_to(output).as_posix(): sha(p)
                       for p in sorted(output.rglob('*')) if p.is_file()}
    (output / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('交叉编译及静态核验通过；未执行 iOS 程序，未生成发行包。', flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::error title=独立逆向扩展交叉编译::' + message, file=sys.stderr, flush=True)
        raise
