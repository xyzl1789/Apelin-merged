#!/usr/bin/env python3
"""从宿主产物目录读取发行包，安全解到项目缓存，再运行真实协议回归。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'build/reverse-analysis'
sys.path.insert(0, str(ROOT / 'Extensions/AgentTools/ReverseAnalysis/Scripts'))
from build_support import tool_path
NAMES = ('xyzl-reverse-analysis', 'xyzl-reverse-worker')


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def code_digest(path):
    # 仅用于测试证明代码与常量未改变；生产缓存仍散列完整文件。
    data = bytearray(path.read_bytes())
    if struct.unpack_from('>I', data)[0] == 0xcafebabe:
        count = struct.unpack_from('>I', data, 4)[0]
        if not 1 <= count <= 4:
            raise RuntimeError('测试产物的 fat 切片数非法')
        slices = [struct.unpack_from('>IIIII', data, 8 + 20 * i)[2:4] for i in range(count)]
    else:
        slices = [(0, len(data))]
    for start, size in slices:
        if struct.unpack_from('<I', data, start)[0] != 0xfeedfacf or start + size > len(data):
            raise RuntimeError('测试产物不是受控的 ARM64 Mach-O')
        commands = struct.unpack_from('<I', data, start + 16)[0]
        offset = start + 32
        for _ in range(commands):
            command, length = struct.unpack_from('<II', data, offset)
            if length < 8 or offset + length > start + size:
                raise RuntimeError('测试产物 load command 越界')
            if command == 0x19:
                sections = struct.unpack_from('<I', data, offset + 64)[0]
                if 72 + sections * 80 > length:
                    raise RuntimeError('测试产物 section 表非法')
                for i in range(sections):
                    section = offset + 72 + 80 * i
                    if data[section:section + 16].rstrip(b'\0') == b'__text' and data[section + 16:section + 24] == b'__TEXT\0\0':
                        data[section + 24:section + 32] = bytes(8)
            if command == 0x1d:
                location, count = struct.unpack_from('<II', data, offset + 8)
                if location + count > size:
                    raise RuntimeError('测试产物签名区域越界')
                data[start + location:start + location + count] = bytes(count)
            offset += length
    return hashlib.sha256(data).hexdigest()


def regression(runtime, label):
    """每个运行目录完整回归两遍，区分首启元数据与代码／权限变化。"""
    before = {name: sha(runtime / name) for name in NAMES}
    code_before = {name: code_digest(runtime / name) for name in NAMES}
    entitlements = {name: subprocess.check_output(['ldid', '-e', str(runtime / name)]) for name in NAMES}
    env = os.environ.copy()
    env['RA_RUNTIME'] = str(runtime)
    env['RA_REPORT_NAME'] = label + '-protocol.json'
    results = CACHE / 'results'
    snapshots = []
    for attempt in ('first', 'repeat'):
        result = subprocess.run([sys.executable, 'Tests/ReverseAnalysis/verify_extension.py'], cwd=ROOT, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        (results / (label + '-' + attempt + '.log')).write_bytes(result.stdout)
        if result.returncode:
            print(result.stdout.decode(errors='replace')[-6500:])
            raise RuntimeError(label + ' 的 ' + attempt + ' 完整协议回归失败')
        snapshots.append({name: sha(runtime / name) for name in NAMES})
        if code_before != {name: code_digest(runtime / name) for name in NAMES}:
            raise RuntimeError(label + ' 的代码或只读数据在执行后变化')
        if entitlements != {name: subprocess.check_output(['ldid', '-e', str(runtime / name)]) for name in NAMES}:
            raise RuntimeError(label + ' 的签名权限在执行后变化')
    if snapshots[0] != snapshots[1]:
        raise RuntimeError(label + ' 首启之后完整文件仍在变化')
    protocol = json.loads((results / env['RA_REPORT_NAME']).read_text())
    faults = protocol.get('component_faults', {})
    expected = ('engine_change_rejected', 'data_index_change_rejected',
                'diagnostic_limit_reaped', 'internal_frame_limit_reaped')
    if not all(faults.get(key) is True for key in expected):
        raise RuntimeError(label + ' 缺少真实故障注入证据')
    print(label + '：两轮完整协议、反编译回编译、故障注入及进程回收均通过。', flush=True)
    return {'before': before, 'after': snapshots[-1], 'protocol_exit_code': 0,
            'code_and_entitlements_unchanged': True, 'repeated_full_hash_stable': True,
            'first_launch_metadata_changed': before != snapshots[0],
            'protocol_report': str((results / env['RA_REPORT_NAME']).relative_to(ROOT)),
            'worker_groups_checked': protocol['worker_groups_checked'], 'component_faults': faults,
            'features': protocol['features'], 'input_unchanged': protocol['input_unchanged']}


def execution_slices(runtime, bootstrap):
    """只运行从包内取出的已签名切片，避免通用文件仅测试到首选架构。"""
    expected = ['arm64e'] if bootstrap == 'roothide' else ['arm64', 'arm64e']
    for name in NAMES:
        arches = subprocess.check_output(['lipo', '-archs', tool_path(runtime / name)]).decode().split()
        if set(arches) != set(expected):
            raise RuntimeError('包内程序架构集合不符：' + name)
    reports = []
    for arch in expected:
        with tempfile.TemporaryDirectory(prefix='slice-' + bootstrap + '-' + arch + '-', dir=CACHE / 'distribution') as scratch:
            thin_runtime = Path(scratch)
            shutil.copytree(runtime / 'sleigh', thin_runtime / 'sleigh')
            shutil.copyfile(runtime / 'data-sha256.json', thin_runtime / 'data-sha256.json')
            for name in NAMES:
                thin = thin_runtime / name
                if len(expected) == 1:
                    shutil.copyfile(runtime / name, thin)
                else:
                    subprocess.run(['lipo', tool_path(runtime / name), '-thin', arch,
                                    '-output', tool_path(thin)], check=True)
                thin.chmod(0o755)
                arches = subprocess.check_output(['lipo', '-archs', tool_path(thin)]).decode().split()
                if arches != [arch]:
                    raise RuntimeError('待执行文件并非唯一指定架构')
                if not subprocess.check_output(['ldid', '-e', str(thin)]).strip():
                    raise RuntimeError('提取切片缺少原有签名权限')
            evidence = regression(thin_runtime, 'package-' + bootstrap + '-' + arch)
            reports.append({'execution_architecture': arch, 'single_slice_confirmed': True,
                            'original_signature_retained': True, **evidence})
    return reports


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-id', required=True)
    parser.add_argument('--bootstrap', choices=['roothide', 'rootless'], required=True)
    parser.add_argument('--digest', required=True)
    args = parser.parse_args()
    if len(args.build_id) != 36 or any(c not in '0123456789abcdef-' for c in args.build_id):
        raise RuntimeError('构建 ID 非法')
    project_id = json.loads((ROOT / 'apelin-project.json').read_text())['projectID']
    packages = list((ROOT.parents[1] / 'Builds' / project_id / args.build_id / 'package').glob('*.deb'))
    if len(packages) != 1:
        raise RuntimeError('构建应含恰好一个软件包')
    package = packages[0]
    if sha(package) != args.digest.removeprefix('sha256:'):
        raise RuntimeError('软件包摘要不符')
    destination = Path(tempfile.mkdtemp(prefix='unpacked-' + args.bootstrap + '-' + args.build_id + '-',
                                        dir=CACHE / 'distribution'))
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(package)], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as source:
            for item in source:
                name = item.name.removeprefix('./')
                if name.startswith('/') or '..' in Path(name).parts:
                    raise RuntimeError('发行包含越界路径')
                path = destination / name
                if not path.resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError('发行包路径越界')
                if item.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                elif item.isfile():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(item) as data, path.open('xb') as out:
                        shutil.copyfileobj(data, out)
                    path.chmod(item.mode)
                else:
                    raise RuntimeError('此发行包不应含链接或设备节点')
        if process.wait():
            raise RuntimeError('发行包无法解开')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill(); process.wait()
    prefix = destination / ('var/jb' if args.bootstrap == 'rootless' else '')
    data = prefix / 'usr/share/apelin/agent-tools/com.xyzl.agent-tools.reverse-analysis'
    manifest = json.loads((data / 'manifest.json').read_text())
    descriptor = json.loads((ROOT / 'Extensions/AgentTools/ReverseAnalysis/Descriptors.json').read_text())
    if any(manifest.get(key) != value for key, value in descriptor.items()):
        raise RuntimeError('包内发现清单与当前工具描述符漂移')
    runtime = prefix / Path(manifest['executable']).parent
    source_info = json.loads((data / 'licenses/source.json').read_text())
    archive = data / source_info['archive']
    if sha(archive) != source_info['sha256']:
        raise RuntimeError('对应源码摘要不符')
    lock = json.loads((ROOT / 'Extensions/AgentTools/ReverseAnalysis/Scripts/sources.json').read_text())['artifacts']
    wanted = {'build/reverse-analysis/' + item['name']: item['sha256'] for item in lock}
    extension = ROOT / 'Extensions/AgentTools/ReverseAnalysis'
    sources = [ROOT / 'LICENSE', *[p for p in sorted(extension.rglob('*'))
               if p.is_file() and not p.is_symlink() and '__pycache__' not in p.parts]]
    wanted.update({p.relative_to(ROOT).as_posix(): sha(p) for p in sources})
    found = {}
    with tarfile.open(archive) as source:
        for item in source:
            if item.name in wanted:
                if item.name in found or not item.isfile():
                    raise RuntimeError('完整对应源码出现重复或非普通文件条目')
                found[item.name] = hashlib.sha256(source.extractfile(item).read()).hexdigest()
    if found != wanted:
        raise RuntimeError('完整对应源码与固定依赖或当前扩展源码不符')
    notices = json.loads((data / 'licenses/notices-sha256.json').read_text())
    if any(sha(data / 'licenses' / name) != digest for name, digest in notices.items()):
        raise RuntimeError('许可通知摘要不符')
    report = {'bootstrap': args.bootstrap, 'build_id': args.build_id, 'digest': args.digest,
              'source_archive_verified': True, 'current_extension_sources_verified': len(sources),
              'discovery_manifest_matches_describe': True, 'notices_verified': len(notices),
              'runtime': str(runtime.relative_to(ROOT))}
    report.update(regression(runtime, 'package-' + args.bootstrap))
    stable = {name: sha(runtime / name) for name in NAMES}
    report['execution_slices'] = execution_slices(runtime, args.bootstrap)
    if stable != {name: sha(runtime / name) for name in NAMES}:
        raise RuntimeError('切片回归意外改动原始解包程序')
    (CACHE / 'results' / ('package-' + args.bootstrap + '-verification.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
