#!/usr/bin/env python3
"""受控构建入口：仅由项目构建宿主调用，生成恰好一个独立扩展包。"""
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

from build_support import (ROOT, EXT, CACHE, LOCK, archives, build_engine, compile_runtime,
                           check_binary, execute, native, relative, sha, tool_path)


def required_environment():
    required = ['APELIN_PACKAGE_DIR', 'APELIN_PROJECT_ROOT', 'APELIN_BOOTSTRAP',
                'APELIN_ARCHITECTURE', 'APELIN_BUILD_ID', 'TMPDIR']
    for key in required:
        if not os.environ.get(key):
            raise RuntimeError(key + ' 未设置；只能通过项目构建宿主调用')
    if 'APELIN_PREFIX' not in os.environ:
        raise RuntimeError('APELIN_PREFIX 必须存在，roothide 时允许为空')
    target = os.environ['APELIN_BOOTSTRAP']
    expected = {'roothide': ('', 'iphoneos-arm64e'), 'rootless': ('/var/jb', 'iphoneos-arm64')}
    if target not in expected or (os.environ['APELIN_PREFIX'], os.environ['APELIN_ARCHITECTURE']) != expected[target]:
        raise RuntimeError('引导类型、安装前缀和软件包架构不一致')
    package_dir = Path(os.environ['APELIN_PACKAGE_DIR']).resolve(strict=True)
    if package_dir == Path('/') or any(package_dir.iterdir()):
        raise RuntimeError('宿主产物目录必须是非根目录且为空')
    return target, package_dir


def notices(r2, ghidra, patch, destination):
    destination.mkdir(parents=True)
    shutil.copyfile(ROOT / 'LICENSE', destination / 'project-LICENSE')
    shutil.copyfile(EXT / 'Packaging/NOTICE.md', destination / 'NOTICE.md')
    for name, root in [('radare2', r2), ('r2ghidra', ghidra), ('patch-ng', patch)]:
        for path in sorted(root.rglob('*')):
            relative_path = path.relative_to(root)
            match = (path.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'COPYRIGHT', 'NOTICE', 'LESSER'))
                     or 'doc/licenses' in relative_path.as_posix()
                     or relative_path.as_posix() == 'doc/licenses.md')
            if not match or not path.is_file() or path.is_symlink():
                continue
            if not path.resolve().is_relative_to(root.resolve()):
                raise RuntimeError('通知文件越过源码根目录')
            target = destination / name / relative_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    hashes = {p.relative_to(destination).as_posix(): sha(p) for p in sorted(destination.rglob('*')) if p.is_file()}
    (destination / 'notices-sha256.json').write_text(json.dumps(hashes, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def source_archive(destination):
    """交付完整源码和依赖原始归档，不带构建目录、私有路径或其他工作区修改。"""
    files = [(ROOT / 'LICENSE', Path('LICENSE'))]
    files += [(p, p.relative_to(ROOT)) for p in sorted(EXT.rglob('*'))
              if p.is_file() and not p.is_symlink() and '__pycache__' not in p.parts]
    files += [(CACHE / item['name'], Path('build/reverse-analysis') / item['name']) for item in LOCK]
    with tarfile.open(destination, 'w:gz', compresslevel=1, format=tarfile.PAX_FORMAT) as archive:
        for source, name in files:
            info = archive.gettarinfo(str(source), arcname=str(name))
            info.uid = info.gid = 0
            info.uname = info.gname = 'root'
            info.mtime = 0
            info.pax_headers = {}
            with source.open('rb') as data:
                archive.addfile(info, data)


def verify_package(package, install_prefix, manifest, expected_files):
    """读取 deb 自身，而不是只检查打包前的暂存目录。"""
    fields = subprocess.check_output(['dpkg-deb', '-f', str(package), 'Package', 'Version', 'Architecture']).decode()
    for value in (manifest['id'], manifest['version'], os.environ['APELIN_ARCHITECTURE']):
        if value not in fields:
            raise RuntimeError('软件包控制字段回读不符')
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(package)], stdout=subprocess.PIPE)
    found = {}
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for item in archive:
                name = item.name.removeprefix('./')
                if item.uid or item.gid or item.mode & 0o022:
                    raise RuntimeError('包内文件权限不是受控 root 所有')
                if item.issym() or item.islnk() or (not item.isfile() and not item.isdir()):
                    raise RuntimeError('软件包不应含链接或特殊节点')
                if item.isfile():
                    if name not in expected_files:
                        raise RuntimeError('包内出现非预期文件：' + name)
                    import hashlib
                    digest = hashlib.sha256()
                    with archive.extractfile(item) as content:
                        for block in iter(lambda: content.read(1048576), b''):
                            digest.update(block)
                    if digest.hexdigest() != expected_files[name]:
                        raise RuntimeError('包内文件摘要不符：' + name)
                    found[name] = digest.hexdigest()
        if process.wait() or set(found) != set(expected_files):
            raise RuntimeError('软件包文件有缺失或无法读取')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill(); process.wait()
    return {'package_sha256': sha(package), 'verified_file_count': len(found),
            'bootstrap': os.environ['APELIN_BOOTSTRAP'], 'architecture': os.environ['APELIN_ARCHITECTURE'],
            'source_embedded': True}


def prepare_ci_version(run_number):
    """同一轮编译与打包使用同一版本；不修改提交中的基础版本。"""
    if not isinstance(run_number, str) or not run_number.isascii() or not run_number.isdigit() or int(run_number) < 1:
        raise RuntimeError('CI 运行序号必须为正整数')
    path = EXT / 'Descriptors.json'
    descriptor = json.loads(path.read_text())
    base, marker, previous = descriptor['version'].partition('+ci.')
    if marker and previous != run_number:
        raise RuntimeError('当前目录已经属于另一轮 CI，不能覆盖')
    if not base or any(c not in '0123456789.' for c in base):
        raise RuntimeError('CI 基础版本必须是点分数字版本')
    descriptor['version'] = base + '+ci.' + run_number
    path.write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + '\n')
    return descriptor


def main(prepared=None):
    target, output = required_environment()
    configurations = ['arm64e'] if target == 'roothide' else ['arm64', 'arm64e']
    built = []
    roots = None
    if prepared is None:
        # 宿主/目标编译器分离后的配方使用新目录，保留 v1 的旧对象与证据。
        os.environ.setdefault('RA_BUILD_TAG', 'native-v2')
        archives()
        for arch in configurations:
            base, r2, ghidra, sleigh, env = build_engine(arch)
            runtime = base / 'runtime'
            compile_runtime(arch, runtime, r2, ghidra, sleigh, env)
            built.append(runtime)
            roots = (r2, ghidra, base / 'deps' / LOCK[3]['directory'] / LOCK[3]['root'])
    else:
        # CI 只封装同一轮已校验的切片；这里不重新编译或下载依赖。
        built = [prepared['runtimes'][arch] for arch in configurations]
    descriptor = json.loads((EXT / 'Descriptors.json').read_text())
    manifest = {**json.loads((EXT / 'Packaging/metadata.json').read_text()), **descriptor}
    if manifest['id'] != 'com.xyzl.agent-tools.reverse-analysis':
        raise RuntimeError('清单包标识符发生意外变化')
    version = manifest['version']
    if not version or any(c not in '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+~-' for c in version):
        raise RuntimeError('版本号非法')
    report_dir = CACHE / 'distribution/reports'
    report_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='reverse-package-', dir=os.environ['TMPDIR']) as temporary:
        stage = Path(temporary)
        stage.chmod(0o755)
        prefix = stage / os.environ['APELIN_PREFIX'].lstrip('/')
        data = prefix / 'usr/share/apelin/agent-tools' / manifest['id']
        runtime = prefix / Path(manifest['executable']).parent
        runtime.mkdir(parents=True)
        data.mkdir(parents=True)
        for name in ('xyzl-reverse-analysis', 'xyzl-reverse-worker'):
            path = runtime / name
            if len(built) == 1:
                shutil.copyfile(built[0] / name, path)
            else:
                subprocess.run(['lipo', '-create', *[tool_path(p / name) for p in built], '-output', tool_path(path)], check=True)
            subprocess.run(['strip', '-x', tool_path(path)], check=True)
            subprocess.run(['ldid', '-S' + str(EXT / 'Packaging/entitlements.plist'), str(path)], check=True)
            path.chmod(0o755)
            if len(configurations) == 1:
                check_binary(path, configurations)
            else:
                # ldid -e 对通用文件连续输出多个 plist；逐切片读取实际签名，不能按单个 plist 解析。
                actual_archs = subprocess.check_output(['lipo', '-archs', tool_path(path)]).decode().split()
                if set(actual_archs) != set(configurations):
                    raise RuntimeError('通用文件的架构集合不符')
                with tempfile.TemporaryDirectory(prefix='reverse-verify-', dir=os.environ['TMPDIR']) as scratch:
                    for arch in configurations:
                        thin = Path(scratch) / arch
                        subprocess.run(['lipo', tool_path(path), '-thin', arch, '-output', tool_path(thin)], check=True)
                        check_binary(thin, [arch])
        shutil.copytree(built[0] / 'sleigh', runtime / 'sleigh')
        shutil.copyfile(built[0] / 'data-sha256.json', runtime / 'data-sha256.json')
        source = data / (manifest['id'] + '_' + version + '_source.tar.gz')
        if prepared is None:
            source_archive(source)
            notices(*roots, data / 'licenses')
        else:
            shutil.copyfile(prepared['source'], source)
            shutil.copytree(prepared['licenses'], data / 'licenses')
        (data / 'licenses/source.json').write_text(json.dumps({
            'archive': source.name, 'sha256': sha(source), 'network_required': False,
            'worker_aggregate_license': 'GPL-3.0-only',
            'build': 'RA_OFFLINE=1 python3 Extensions/AgentTools/ReverseAnalysis/Scripts/rebuild.py --arch arm64e'}, ensure_ascii=False, indent=2) + '\n')
        (data / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        for entry in manifest['licenseFiles']:
            if not (data / entry).is_file():
                raise RuntimeError('清单许可文件缺失：' + entry)
        for path in stage.rglob('*'):
            if path.is_dir():
                path.chmod(0o755)
            elif path.name not in ('xyzl-reverse-analysis', 'xyzl-reverse-worker'):
                path.chmod(0o644)
        expected = {p.relative_to(stage).as_posix(): sha(p) for p in stage.rglob('*') if p.is_file()}
        control = (EXT / 'Packaging/control.in').read_text()
        size = sum(p.stat().st_size for p in stage.rglob('*') if p.is_file())
        for key, value in {'VERSION': version, 'ARCHITECTURE': os.environ['APELIN_ARCHITECTURE'], 'INSTALLED_SIZE': str((size + 1023) // 1024)}.items():
            control = control.replace('@' + key + '@', value)
        if '@' in control:
            raise RuntimeError('控制文件仍有未替换占位符')
        (stage / 'DEBIAN').mkdir()
        (stage / 'DEBIAN/control').write_text(control)
        package = output / (manifest['id'] + '_' + version + '_' + os.environ['APELIN_ARCHITECTURE'] + '.deb')
        subprocess.run(['dpkg-deb', '--root-owner-group', '-Zgzip', '-z1', '-b', str(stage), str(package)], check=True)
        report = verify_package(package, os.environ['APELIN_PREFIX'], manifest, expected)
        report.update({'source_sha256': sha(source), 'source_bytes': source.stat().st_size, 'code_architectures': configurations})
        (report_dir / (target + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    print('独立扩展包已生成并从包内逐文件核验；未安装。', flush=True)


if __name__ == '__main__':
    main()
