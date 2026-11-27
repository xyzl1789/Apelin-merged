#!/usr/bin/env python3
"""独立扩展的固定依赖与原生构建；不安装软件，不生成 deb。"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import tarfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[4]
EXT = ROOT / 'Extensions/AgentTools/ReverseAnalysis'
CACHE = ROOT / 'build/reverse-analysis'
LOCK = json.loads((EXT / 'Scripts/sources.json').read_text())['artifacts']
PLUGINS = ['bin_demangle.cxx', 'bin_demangle.objc', 'bin_demangle.swift', 'anal.null', 'anal.autoname', 'arch.arm', 'arch.arm_cs', 'arch.null', 'esil.null', 'esil.dummy', 'bin.null', 'bin.mach0', 'bin.mach064', 'bp.arm', 'bp.null', 'core.agD', 'core.pseudo', 'core.prj', 'debug.esil', 'debug.io', 'fs.posix', 'fs.fatmacho', 'io.default', 'io.mmap', 'io.malloc', 'io.sparse', 'asm.null']


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def relative(path):
    return str(Path(path).relative_to(ROOT))


def native(path):
    return os.environ['APELIN_PROJECT_ROOT'].rstrip('/') + '/' + relative(path)


def execute(label, args, cwd, env, timeout=1200):
    logs = CACHE / 'distribution/logs'
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / (label + '.log')
    started = time.monotonic()
    with log.open('wb') as output:
        child = subprocess.Popen(list(map(str, args)), cwd=cwd, env=env,
                                 stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = child.wait(timeout)
        except BaseException:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise
    print(f'{label}：退出码 {status}，{time.monotonic() - started:.1f} 秒', flush=True)
    if status:
        print(log.read_text(errors='replace')[-6000:], flush=True)
        raise RuntimeError(f'构建失败，日志：{relative(log)}')


def unpack(archive, destination):
    """仅写全新目录；禁止越界链接、设备节点及过量解包。"""
    destination.mkdir(parents=True)
    def target(name):
        if not name or name.startswith('/') or '..' in Path(name).parts:
            raise RuntimeError('依赖归档含越界路径')
        result = destination / name
        if not result.resolve().is_relative_to(destination.resolve()):
            raise RuntimeError('依赖归档路径穿过越界链接')
        return result
    total = 0
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                total += item.file_size
                if total > 1024 ** 3 or stat.S_ISLNK(item.external_attr >> 16):
                    raise RuntimeError('依赖 ZIP 超限或含链接')
                dest = target(item.filename)
                if item.is_dir():
                    dest.mkdir(parents=True, exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with source.open(item) as src, dest.open('xb') as out:
                        shutil.copyfileobj(src, out)
    else:
        with tarfile.open(archive) as source:
            links = []
            for item in source:
                total += item.size
                if total > 1024 ** 3:
                    raise RuntimeError('依赖源码超出解包限制')
                dest = target(item.name)
                if item.isdir():
                    dest.mkdir(parents=True, exist_ok=True)
                elif item.isfile():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(item) as src, dest.open('xb') as out:
                        shutil.copyfileobj(src, out)
                    dest.chmod(item.mode & 0o777)
                elif item.issym() or item.islnk():
                    links.append((item, dest))
                else:
                    raise RuntimeError('源码归档含特殊节点')
            for item, dest in links:
                dest.parent.mkdir(parents=True, exist_ok=True)
                link = dest.parent / item.linkname if item.issym() else destination / item.linkname
                if Path(item.linkname).is_absolute() or not link.resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError('源码链接越界')
                if item.issym():
                    dest.symlink_to(item.linkname)
                else:
                    os.link(link, dest)


def archives():
    CACHE.mkdir(parents=True, exist_ok=True)
    for item in LOCK:
        archive = CACHE / item['name']
        if not archive.exists():
            if os.environ.get('RA_OFFLINE') == '1':
                raise RuntimeError('离线源码缺失：' + item['name'])
            part = archive.with_suffix(archive.suffix + '.part')
            request = urllib.request.Request(item['url'], headers={'User-Agent': 'NativeReverseAnalysis/0.1'})
            with urllib.request.urlopen(request, timeout=90) as source, part.open('wb') as out:
                shutil.copyfileobj(source, out, 1048576)
            if part.stat().st_size != item['bytes'] or sha(part) != item['sha256']:
                raise RuntimeError('下载依赖摘要不符')
            part.rename(archive)
        if archive.stat().st_size != item['bytes'] or sha(archive) != item['sha256']:
            raise RuntimeError('依赖归档已变化：' + item['name'])


def prepare(base):
    result = []
    for item in LOCK:
        destination = base / item['directory']
        marker = destination / '.verified-sha256'
        if destination.exists():
            if not marker.is_file() or marker.read_text().strip() != item['sha256']:
                raise RuntimeError('保留未完成的源码目录，请另选 RA_BUILD_TAG 后重试')
        else:
            unpack(CACHE / item['name'], destination)
            marker.write_text(item['sha256'] + '\n')
        result.append(destination / item['root'])
    return result


def cross_compile():
    value = os.environ.get('RA_CROSS_COMPILE', '0')
    if value not in ('0', '1'):
        raise RuntimeError('RA_CROSS_COMPILE 只能为 0 或 1')
    return value == '1'


def environment(arch, patch):
    if arch not in ('arm64', 'arm64e'):
        raise RuntimeError('目标架构必须为 arm64 或 arm64e')
    if not os.environ.get('APELIN_PROJECT_ROOT'):
        raise RuntimeError('项目环境缺少 APELIN_PROJECT_ROOT')
    env = os.environ.copy()
    cross = cross_compile()
    if cross:
        for name in ('SDKROOT', 'RA_HOST_SDKROOT'):
            if not env.get(name) or not Path(env[name]).is_dir():
                raise RuntimeError('交叉编译缺少有效 SDK 目录：' + name)
        if Path(env['SDKROOT']).resolve() == Path(env['RA_HOST_SDKROOT']).resolve():
            raise RuntimeError('交叉编译的 iPhoneOS 与 macOS SDK 不得相同')
        env['APELIN_REVERSE_HOST_SDKROOT'] = env['RA_HOST_SDKROOT']
    archiver = shutil.which('ar')
    if not archiver:
        raise RuntimeError('工具链缺少 ar')
    for wrapper in (EXT / 'Scripts/bin').iterdir():
        wrapper.chmod(0o755)
    env['PATH'] = native(EXT / 'Scripts/bin') + ':' + env['PATH']
    env['APELIN_REVERSE_ARCH'] = arch
    env['APELIN_REVERSE_AR'] = archiver
    env['APELIN_REVERSE_ENTITLEMENTS'] = native(EXT / 'Packaging/entitlements.plist')
    env['APELIN_REVERSE_PATCH'] = native(patch / 'patch_ng.py')
    maps = ' '.join('-ffile-prefix-map=' + value + '=.' for value in
                    {str(ROOT), os.environ['APELIN_PROJECT_ROOT']})
    common = f'-O2 -arch {arch} -miphoneos-version-min=16.0 -fPIC {maps}'
    host_cc = 'reverse-host-cc' if cross else 'reverse-cc'
    env.update({'CC': 'reverse-cc', 'CXX': 'reverse-cxx', 'HOST_CC': host_cc,
                'HOSTCC': host_cc, 'CC_FOR_BUILD': host_cc, 'WANT_ZYDIS': '0',
                'HOST_CFLAGS': '-O2 ' + maps, 'HOST_LDFLAGS': '',
                'CAPSTONE_ARCHS': 'arm aarch64', 'PYTHON': 'python3', 'CFLAGS': common,
                'CXXFLAGS': common + ' -stdlib=libc++',
                'LDFLAGS': f'-arch {arch} -miphoneos-version-min=16.0'})
    return env


def engine_key(arch):
    h = hashlib.sha256()
    inputs = [EXT / 'Scripts/build_support.py', EXT / 'Scripts/sources.json', *(EXT / 'Scripts/bin').iterdir()]
    for path in sorted(inputs):
        if path.is_file():
            h.update(str(path.relative_to(EXT)).encode())
            h.update(path.read_bytes())
    h.update((EXT / 'Packaging/entitlements.plist').read_bytes())
    h.update(arch.encode())
    h.update(str(cross_compile()).encode())
    if cross_compile():
        host_sdk = os.environ.get('RA_HOST_SDKROOT')
        if not host_sdk:
            raise RuntimeError('交叉编译缺少 RA_HOST_SDKROOT')
        host_settings = Path(host_sdk) / 'SDKSettings.plist'
        h.update(host_settings.read_bytes())
    version = subprocess.check_output(['clang', '--version']).decode().splitlines()[0]
    h.update(version.encode())
    sdk = Path(os.environ['SDKROOT']) / 'SDKSettings.plist'
    if sdk.is_file():
        h.update(sdk.read_bytes())
    return h.hexdigest()


def build_engine(arch, jobs=2):
    tag = os.environ.get('RA_BUILD_TAG', 'v1')
    if not tag or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in tag):
        raise RuntimeError('RA_BUILD_TAG 必须为非空安全标识符')
    base = CACHE / 'distribution' / tag / arch
    key = engine_key(arch)
    base.mkdir(parents=True, exist_ok=True)
    r2, ghidra, sleigh, patch = prepare(base / 'deps')
    env = environment(arch, patch)
    marker = base / 'engine.json'
    if marker.is_file():
        saved = json.loads(marker.read_text())
        if saved['key'] != key:
            raise RuntimeError('构建配方已变化，请另选 RA_BUILD_TAG，不能混用旧对象')
        if all((base / name).is_file() and sha(base / name) == digest for name, digest in saved['files'].items()):
            return base, r2, ghidra, sleigh, env
        raise RuntimeError('引擎对象缓存已变化，请另选 RA_BUILD_TAG')
    label = arch + '-'
    execute(label + 'configure', ['sh', 'configure', '--prefix=/usr', '--host=arm64-apple-darwin',
        '--target=arm64-apple-darwin', '--with-ostype=darwin', '--with-compiler=clang', '--with-libr',
        '--without-gpl', '--without-qjs', '--without-zydis', '--without-gperf', '--without-zip',
        '--disable-debugger', '--disable-network'], r2, env, 180)
    (r2 / 'plugins.cfg').write_text('STATIC="\n' + '\n'.join(PLUGINS) + '\n"\nSHARED=""\n')
    execute(label + 'plugins', ['sh', 'configure-plugins'], r2, env, 60)
    for name in ('shlr/Makefile', 'libr/Makefile'):
        path = r2 / name
        path.write_text(path.read_text().replace('xcrun libtool -static', 'libtool -static').replace('xcrun ranlib ', 'ranlib '))
    path = r2 / 'libr/syscall/d/Makefile'
    path.write_text(path.read_text().replace('$(SDB) -r -r $(shell pwd)', '$(SDB) -r -r .'))
    execute(label + 'radare2', ['make', f'-j{jobs}', 'blob', 'CC=reverse-cc', 'HOST_CC=' + env['HOST_CC'],
        'HOSTCC=' + env['HOSTCC'], 'CC_FOR_BUILD=' + env['CC_FOR_BUILD'], 'AR=reverse-ar', 'CAPSTONE_ARCHS=arm aarch64'], r2, env)
    execute(label + 'archive', ['make', '-C', 'libr', 'libr.a', 'AR=reverse-ar'], r2, env, 180)
    src = ghidra / 'src'
    include = '-I' + os.path.relpath(r2 / 'libr/include', src) + ' -I' + os.path.relpath(r2 / 'subprojects/sdb/include', src)
    (ghidra / 'config.mk').write_text('CXX=reverse-cxx\nVERSION=6.2.6\nR2_USER_PLUGINS=reverse-analysis\nR2_LIBR_PLUGINS=reverse-analysis\nR2_CFLAGS=' + include + '\nR2_LDFLAGS=\n')
    (ghidra / 'config.h').write_text('#define R2GHIDRA_CONFIG_H 1\n#define R2GHIDRA_VERSION "6.2.6"\n')
    path = src / 'Makefile'
    path.write_text(path.read_text() + '\n# 避免 zconf.h 改写与并行编译竞争；只构建静态对象。\n$(R2GHIDRA_OBJS) $(GHIDRA_OBJS) $(R2G_PLUGIN_OBJS): | ../subprojects/zlib/libz.a\nreverse-static: $(R2GHIDRA_OBJS) $(GHIDRA_OBJS) core_ghidra.o anal_ghidra.o\n')
    execute(label + 'ghidra', ['make', f'-j{jobs}', 'R2_LIBEXT=dylib', 'reverse-static'], src, env)
    includes = ['-I' + relative(r2 / 'libr/include'), '-I' + relative(r2 / 'subprojects/sdb/include')]
    for name in ('core', 'anal'):
        execute(label + name, ['reverse-cc', '-O2', '-arch', arch, '-DR2_PLUGIN_INCORE=1', *includes,
            '-c', relative(src / (name + '_ghidra_plugin.c')), '-o', relative(src / (name + '_ghidra_static.o'))], ROOT, env, 60)
    objects = engine_objects(ghidra)
    files = [r2 / 'libr/libr.a', ghidra / 'subprojects/zlib/libz.a', *objects]
    marker.write_text(json.dumps({'key': key, 'files': {str(p.relative_to(base)): sha(p) for p in files}}, sort_keys=True, indent=2) + '\n')
    return base, r2, ghidra, sleigh, env


def engine_objects(ghidra):
    objects = sorted({p for p in (ghidra / 'src').glob('*.o') if not p.name.endswith('_plugin.o')} |
                     set((ghidra / 'subprojects/ghidra-native/src/decompiler').glob('*.o')))
    if len(objects) < 40:
        raise RuntimeError('Ghidra 静态对象不完整')
    return objects


def compile_runtime(arch, destination, r2, ghidra, sleigh, env):
    destination.mkdir(parents=True, exist_ok=True)
    descriptors = (EXT / 'Descriptors.json').read_bytes()
    (destination / 'Descriptors.inc').write_text('static const unsigned char RADescriptors[] = {' + ','.join(map(str, descriptors)) + '};\n')
    maps = ['-ffile-prefix-map=' + value + '=.' for value in {str(ROOT), os.environ['APELIN_PROJECT_ROOT']}]
    flags = ['-arch', arch, '-O2', '-miphoneos-version-min=16.0', *maps, '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations']
    sources = [relative(EXT / 'Sources' / name) for name in ('Analysis.m', 'Server.m', 'main.m')]
    execute(arch + '-server', ['reverse-cc', *flags, '-fobjc-arc', '-fblocks', '-I' + relative(destination),
        '-I' + relative(EXT / 'Sources'), *sources, '-framework', 'Foundation', '-o', relative(destination / 'xyzl-reverse-analysis')], ROOT, env, 120)
    worker = destination / 'worker.o'
    includes = ['-I' + relative(r2 / 'libr/include'), '-I' + relative(r2 / 'subprojects/sdb/include')]
    execute(arch + '-worker', ['reverse-cc', *flags, *includes, '-c', relative(EXT / 'Sources/Worker.c'), '-o', relative(worker)], ROOT, env, 60)
    inputs = [worker, *engine_objects(ghidra), ghidra / 'subprojects/zlib/libz.a', r2 / 'libr/libr.a']
    execute(arch + '-link', ['reverse-cxx', '-arch', arch, '-miphoneos-version-min=16.0', '-o',
        relative(destination / 'xyzl-reverse-worker'), *map(relative, inputs)], ROOT, env, 120)
    data = destination / 'sleigh'
    data.mkdir(exist_ok=True)
    for source in sleigh.iterdir():
        if source.name.startswith('AARCH64') or source.name == 'AppleSilicon.ldefs':
            shutil.copyfile(source, data / source.name)
    hashes = {p.name: sha(p) for p in sorted(data.iterdir()) if p.is_file()}
    if len(hashes) < 8:
        raise RuntimeError('ARM64 语言数据不完整')
    (destination / 'data-sha256.json').write_text(json.dumps(hashes, sort_keys=True, indent=2) + '\n')


def tool_path(path):
    path = Path(path)
    if path.is_relative_to(ROOT):
        return native(path)
    value = str(path)
    return value.removeprefix('/rootfs') if value.startswith('/rootfs/') else value


def is_ios_header(headers):
    return (re.search(r'^\s*platform\s+(?:2|IOS)\s*$', headers, re.MULTILINE) is not None
            or 'LC_VERSION_MIN_IPHONEOS' in headers)


def check_binary(path, expected):
    archs = subprocess.check_output(['lipo', '-archs', tool_path(path)]).decode().split()
    if set(archs) != set(expected):
        raise RuntimeError('二进制架构不符：' + path.name + str(archs))
    deps = subprocess.check_output(['otool', '-L', tool_path(path)]).decode()
    for line in deps.splitlines():
        if 'compatibility version' in line and not line.strip().startswith(('/usr/lib/', '/System/Library/')):
            raise RuntimeError('存在非系统动态依赖：' + line)
    for arch in expected:
        headers = subprocess.check_output(['otool', '-arch', arch, '-l', tool_path(path)]).decode()
        if not is_ios_header(headers):
            raise RuntimeError('不是 iOS 目标')
    data = path.read_bytes()
    for value in {str(ROOT), os.environ['APELIN_PROJECT_ROOT'], str(Path.home())}:
        if len(value) > 8 and value.encode() in data:
            raise RuntimeError('二进制残留私有构建路径：' + path.name)
    expected_plist = (EXT / 'Packaging/entitlements.plist').read_bytes()
    import plistlib
    actual = subprocess.check_output(['ldid', '-e', str(path)])
    if plistlib.loads(actual) != plistlib.loads(expected_plist):
        raise RuntimeError('签名权限与审查值不符')
