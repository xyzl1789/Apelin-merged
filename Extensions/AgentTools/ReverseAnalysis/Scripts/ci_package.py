#!/usr/bin/env python3
"""封装同轮已核验的 CI 切片，或汇总已核验安装包；不重新编译。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile

import build_package
import ci_build
from build_support import ROOT, EXT, CACHE, LOCK, sha

PACKAGE_ID = 'com.xyzl.agent-tools.reverse-analysis'
TARGETS = {'roothide': ('', 'iphoneos-arm64e', ['arm64e']),
           'rootless': ('/var/jb', 'iphoneos-arm64', ['arm64', 'arm64e'])}


def provenance():
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('此入口仅供 GitHub 工作流封装；本机使用正式项目构建入口')
    commit, run_id = os.environ.get('GITHUB_SHA', ''), os.environ.get('GITHUB_RUN_ID', '')
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or not re.fullmatch(r'[1-9][0-9]*', run_id):
        raise RuntimeError('缺少可信的 CI 提交或运行标识')
    return commit, run_id


def regular_files(root):
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError('输入目录不存在或是链接')
    files = {}
    for path in root.rglob('*'):
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise RuntimeError('输入中含链接或特殊节点：' + str(path.relative_to(root)))
        files[path.relative_to(root).as_posix()] = path
    return files


def verify_source(source):
    """逐项核对完整对应源码；不解包、不执行归档内的脚本。"""
    project = [ROOT / 'LICENSE', *[p for p in sorted(EXT.rglob('*'))
               if p.is_file() and not p.is_symlink() and '__pycache__' not in p.parts]]
    expected = {p.relative_to(ROOT).as_posix(): (p.stat().st_size, sha(p)) for p in project}
    expected.update({'build/reverse-analysis/' + item['name']: (item['bytes'], item['sha256']) for item in LOCK})
    found = set()
    with tarfile.open(source, 'r:gz') as archive:
        for member in archive:
            name = member.name
            if not member.isfile() or name not in expected or name in found or member.size != expected[name][0]:
                raise RuntimeError('对应源码文件集合、大小或节点类型不符：' + name)
            digest = hashlib.sha256()
            with archive.extractfile(member) as content:
                for block in iter(lambda: content.read(1048576), b''):
                    digest.update(block)
            if digest.hexdigest() != expected[name][1]:
                raise RuntimeError('对应源码摘要不符：' + name)
            found.add(name)
    if found != set(expected):
        raise RuntimeError('完整对应源码有缺失')
    return len(found)


def verify_artifact(runtime, arch, descriptor):
    commit, run_id = provenance()
    files = regular_files(runtime)
    if 'verification.json' not in files:
        raise RuntimeError('编译产物缺少静态核验报告')
    report = json.loads(files.pop('verification.json').read_text())
    for key, value in {'commit': commit, 'run_id': run_id, 'version': descriptor['version'],
                       'architectures': [arch], 'ios_binaries_executed': False,
                       'device_acceptance': False, 'packaged': False, 'installed': False,
                       'ios_platform_checked': True, 'system_dependencies_only': True,
                       'entitlements_checked': True, 'private_paths_absent': True}.items():
        if report.get(key) != value:
            raise RuntimeError('产物批次或核验状态不符：' + key)
    actual = {name: sha(path) for name, path in files.items()}
    if report.get('files') != actual:
        raise RuntimeError('编译产物文件集合或摘要不符')
    if json.loads((runtime / 'Descriptors.json').read_text()) != descriptor:
        raise RuntimeError('产物工具声明与本轮版本不符')
    ci_build.verify_runtime(runtime, arch)
    notices = json.loads((runtime / 'licenses/notices-sha256.json').read_text())
    license_files = regular_files(runtime / 'licenses')
    license_files.pop('notices-sha256.json', None)
    if notices != {name: sha(path) for name, path in license_files.items()}:
        raise RuntimeError('许可文件集合或摘要不符')
    return report


def prepare_inputs(root, descriptor):
    reports = {}
    for arch in ('arm64', 'arm64e'):
        reports[arch] = verify_artifact(root / arch, arch, descriptor)
    for name in ('data-sha256.json',):
        if (root / 'arm64' / name).read_bytes() != (root / 'arm64e' / name).read_bytes():
            raise RuntimeError('两架构的语言数据清单不一致')
    # 两个源码 gzip 的时间头可能不同；逐项核对内容，不把外层 gzip 摘要当作源码身份。
    for arch in ('arm64', 'arm64e'):
        verify_source(root / arch / 'corresponding-source.tar.gz')
    canonical = root / 'arm64e'
    return {'runtimes': {arch: root / arch for arch in ('arm64', 'arm64e')},
            'source': canonical / 'corresponding-source.tar.gz',
            'licenses': canonical / 'licenses', 'input_reports': reports}


def package(root):
    if sys.platform != 'darwin' or not shutil.which('xcrun'):
        raise RuntimeError('CI 打包需要 macOS/Xcode 的静态工具；不能在此执行 iOS 程序')
    commit, run_id = provenance()
    target, output = build_package.required_environment()
    descriptor = build_package.prepare_ci_version(os.environ.get('GITHUB_RUN_NUMBER'))
    prepared = prepare_inputs(root, descriptor)
    build_package.main(prepared=prepared)
    report = json.loads((CACHE / 'distribution/reports' / (target + '.json')).read_text())
    packages = list(output.glob('*.deb'))
    if len(packages) != 1:
        raise RuntimeError('每个引导类型必须只生成一个安装包')
    source_name = PACKAGE_ID + '_' + descriptor['version'] + '_source.tar.gz'
    report.update({'package': packages[0].name, 'package_id': PACKAGE_ID,
                   'version': descriptor['version'], 'commit': commit, 'run_id': run_id,
                   'ios_binaries_executed': False, 'device_acceptance': False,
                   'installed': False, 'source_name': source_name,
                   'source_sha256': sha(prepared['source'])})
    (output / (target + '-verification.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    if target == 'roothide':
        shutil.copyfile(prepared['source'], output / source_name)
    print('已生成并回读核验 ' + target + ' 安装包；未安装、未执行 iOS 程序。', flush=True)


def collect_release(root):
    commit, run_id = provenance()
    descriptor = build_package.prepare_ci_version(os.environ.get('GITHUB_RUN_NUMBER'))
    version = descriptor['version']
    files = regular_files(root)
    expected, source_hash = set(), None
    for target, (_, arch, slices) in TARGETS.items():
        report_name = target + '-verification.json'
        report = json.loads((root / report_name).read_text())
        package_name = PACKAGE_ID + '_' + version + '_' + arch + '.deb'
        for key, value in {'package': package_name, 'package_id': PACKAGE_ID,
                           'version': version, 'commit': commit, 'run_id': run_id,
                           'bootstrap': target, 'architecture': arch, 'code_architectures': slices,
                           'source_embedded': True, 'ios_binaries_executed': False,
                           'device_acceptance': False, 'installed': False}.items():
            if report.get(key) != value:
                raise RuntimeError('发行包报告不符：' + target + '/' + key)
        if report['package_sha256'] != sha(root / package_name):
            raise RuntimeError('发行安装包摘要不符：' + target)
        if source_hash is not None and source_hash != report['source_sha256']:
            raise RuntimeError('两个安装包的对应源码不一致')
        source_hash = report['source_sha256']
        expected.update((package_name, report_name))
    source_name = PACKAGE_ID + '_' + version + '_source.tar.gz'
    expected.add(source_name)
    if set(files) != expected or sha(root / source_name) != source_hash:
        raise RuntimeError('发行文件集合或对应源码摘要不符')
    notes = EXT / 'Releases' / (version.split('+ci.')[0] + '.md')
    if not notes.is_file():
        raise RuntimeError('缺少本版本的中文发行说明')
    (root / 'SHA256SUMS').write_text(''.join(sha(files[name]) + '  ' + name + '\n' for name in sorted(files)))
    result = {'version': version, 'tag': 'reverse-analysis-v' + version.replace('+', '-'),
              'notes': str(notes), 'package_count': 2}
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for key in ('version', 'tag', 'notes'):
                output.write(key + '=' + result[key] + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-root', required=True, type=Path)
    parser.add_argument('--collect-release', action='store_true')
    args = parser.parse_args()
    if args.collect_release:
        result = collect_release(args.input_root)
        print('已核验两份安装包及完整源码，生成 SHA256SUMS：' + result['version'], flush=True)
    else:
        package(args.input_root)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        message = str(error).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::error title=独立逆向扩展安装包::' + message, file=sys.stderr, flush=True)
        raise
