#!/usr/bin/env python3
"""安装包交付契约测试：只用临时数据，不生成 deb、不执行 iOS 程序。"""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'Extensions/AgentTools/ReverseAnalysis/Scripts'
sys.path.insert(0, str(SCRIPTS))
import build_package
import ci_build
import ci_package


class PackageContractTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / 'build/reverse-analysis/package-contract-tests'
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / 'project'
        self.ext = self.root / 'Extensions/AgentTools/ReverseAnalysis'
        (self.ext / 'Packaging').mkdir(parents=True)
        (self.ext / 'Releases').mkdir()
        (self.ext / 'Releases/0.1.3.md').write_text('中文发行说明\n')
        (self.root / 'LICENSE').write_text('MIT fixture\n')
        descriptor = json.loads((SCRIPTS.parent / 'Descriptors.json').read_text())
        descriptor['version'] = '0.1.3'
        (self.ext / 'Descriptors.json').write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + '\n')
        (self.ext / 'Packaging/metadata.json').write_bytes((SCRIPTS.parent / 'Packaging/metadata.json').read_bytes())
        self.lock = [{'name': 'dependency.tar.xz', 'bytes': 3, 'sha256': hashlib.sha256(b'abc').hexdigest()}]
        self.env = {'GITHUB_ACTIONS': 'true', 'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123',
                    'GITHUB_RUN_NUMBER': '77', 'GITHUB_OUTPUT': str(self.work / 'outputs'),
                    'APELIN_PROJECT_ROOT': str(self.root), 'APELIN_BOOTSTRAP': 'roothide',
                    'APELIN_ARCHITECTURE': 'iphoneos-arm64e', 'APELIN_PREFIX': '',
                    'APELIN_BUILD_ID': 'fixture', 'TMPDIR': str(self.work),
                    'APELIN_PACKAGE_DIR': str(self.work / 'packages')}
        Path(self.env['APELIN_PACKAGE_DIR']).mkdir()
        patches = [mock.patch.dict(os.environ, self.env),
                   mock.patch.object(build_package, 'EXT', self.ext),
                   mock.patch.object(build_package, 'CACHE', self.work / 'cache'),
                   mock.patch.object(ci_package, 'ROOT', self.root),
                   mock.patch.object(ci_package, 'EXT', self.ext),
                   mock.patch.object(ci_package, 'LOCK', self.lock),
                   mock.patch.object(ci_build, 'check_binary')]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.descriptor = build_package.prepare_ci_version('77')

    def source(self, path):
        with tarfile.open(path, 'w:gz') as archive:
            for source in [self.root / 'LICENSE', *sorted(self.ext.rglob('*'))]:
                if source.is_file():
                    archive.add(source, arcname=source.relative_to(self.root).as_posix())
            info = tarfile.TarInfo('build/reverse-analysis/dependency.tar.xz')
            info.size = 3
            archive.addfile(info, io.BytesIO(b'abc'))

    def refresh(self, runtime):
        path = runtime / 'verification.json'
        report = json.loads(path.read_text())
        report['files'] = {name: ci_package.sha(value) for name, value in ci_package.regular_files(runtime).items()
                           if name != 'verification.json'}
        path.write_text(json.dumps(report))

    def artifact(self, arch):
        runtime = self.work / 'input' / arch
        (runtime / 'sleigh').mkdir(parents=True)
        (runtime / 'licenses').mkdir()
        for name in ci_build.NAMES:
            (runtime / name).write_bytes((name + '-' + arch).encode())
        index = {}
        for i in range(8):
            path = runtime / 'sleigh' / str(i)
            path.write_bytes(bytes([i]))
            index[path.name] = ci_package.sha(path)
        (runtime / 'data-sha256.json').write_text(json.dumps(index))
        (runtime / 'Descriptors.json').write_text(json.dumps(self.descriptor))
        (runtime / 'licenses/NOTICE.md').write_text('上游许可\n')
        (runtime / 'licenses/notices-sha256.json').write_text(json.dumps({'NOTICE.md': ci_package.sha(runtime / 'licenses/NOTICE.md')}))
        self.source(runtime / 'corresponding-source.tar.gz')
        report = {**ci_build.verify_runtime(runtime, arch), 'commit': self.env['GITHUB_SHA'],
                  'run_id': '123', 'version': self.descriptor['version'], 'packaged': False, 'installed': False}
        (runtime / 'verification.json').write_text(json.dumps(report))
        self.refresh(runtime)
        return runtime

    def release(self):
        root = self.work / 'release'
        root.mkdir()
        version = self.descriptor['version']
        source_name = ci_package.PACKAGE_ID + '_' + version + '_source.tar.gz'
        (root / source_name).write_bytes(b'source fixture')
        for target, (_, arch, slices) in ci_package.TARGETS.items():
            name = ci_package.PACKAGE_ID + '_' + version + '_' + arch + '.deb'
            (root / name).write_bytes(('package fixture-' + target).encode())
            report = {'package': name, 'package_id': ci_package.PACKAGE_ID,
                      'version': version, 'commit': self.env['GITHUB_SHA'], 'run_id': '123',
                      'bootstrap': target, 'architecture': arch, 'code_architectures': slices,
                      'source_embedded': True, 'ios_binaries_executed': False,
                      'device_acceptance': False, 'installed': False,
                      'package_sha256': ci_package.sha(root / name),
                      'source_sha256': ci_package.sha(root / source_name)}
            (root / (target + '-verification.json')).write_text(json.dumps(report))
        return root

    def test_package_author_and_maintainer_credit(self):
        control = (ROOT / 'Extensions/AgentTools/ReverseAnalysis/Packaging/control.in').read_text()
        self.assertIn('Maintainer: xyzl\n', control)
        self.assertNotIn('Maintainer: xyzl1789', control)
        self.assertIn('Author: xyzl 和上游贡献者\n', control)
        self.assertNotIn('Author: xyzl1789', control)

    def test_ci_version_is_shared_and_idempotent(self):
        self.assertEqual(build_package.prepare_ci_version('77')['version'], '0.1.3+ci.77')

    def test_ci_version_rejects_invalid_run_number(self):
        for value in (None, '', '0', '-1', 'one', '７７', '77\n', '../77'):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, '序号'):
                build_package.prepare_ci_version(value)

    def test_ci_version_rejects_other_run(self):
        with self.assertRaisesRegex(RuntimeError, '另一轮'):
            build_package.prepare_ci_version('78')

    def test_provenance_requires_actions_and_valid_commit(self):
        with mock.patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), self.assertRaises(RuntimeError):
            ci_package.provenance()
        with mock.patch.dict(os.environ, {'GITHUB_SHA': 'wrong'}), self.assertRaises(RuntimeError):
            ci_package.provenance()

    def test_artifact_rechecks_hashes_and_static_binary_properties(self):
        runtime = self.artifact('arm64')
        report = ci_package.verify_artifact(runtime, 'arm64', self.descriptor)
        self.assertEqual(report['architectures'], ['arm64'])
        ci_build.check_binary.assert_any_call(runtime / ci_build.NAMES[0], ['arm64'])
        (runtime / ci_build.NAMES[0]).write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, '摘要'):
            ci_package.verify_artifact(runtime, 'arm64', self.descriptor)

    def test_artifact_rejects_wrong_commit_or_architecture(self):
        runtime = self.artifact('arm64')
        for key, value in [('commit', 'b' * 40), ('architectures', ['arm64e']), ('device_acceptance', True)]:
            path = runtime / 'verification.json'
            original = json.loads(path.read_text())
            changed = {**original, key: value}
            path.write_text(json.dumps(changed))
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, '状态不符'):
                ci_package.verify_artifact(runtime, 'arm64', self.descriptor)
            path.write_text(json.dumps(original))

    def test_artifact_rejects_extra_files(self):
        runtime = self.artifact('arm64')
        (runtime / 'unexpected').write_text('not declared')
        with self.assertRaisesRegex(RuntimeError, '文件集合'):
            ci_package.verify_artifact(runtime, 'arm64', self.descriptor)

    def test_artifact_rejects_symlinks(self):
        runtime = self.artifact('arm64')
        (runtime / 'link').symlink_to('Descriptors.json')
        with self.assertRaisesRegex(RuntimeError, '链接'):
            ci_package.verify_artifact(runtime, 'arm64', self.descriptor)

    def test_license_index_is_checked_independently(self):
        runtime = self.artifact('arm64')
        (runtime / 'licenses/NOTICE.md').write_text('changed')
        self.refresh(runtime)
        with self.assertRaisesRegex(RuntimeError, '许可'):
            ci_package.verify_artifact(runtime, 'arm64', self.descriptor)

    def test_full_corresponding_source_is_verified_without_extraction(self):
        path = self.work / 'source.tar.gz'
        self.source(path)
        self.assertGreater(ci_package.verify_source(path), 3)
        (self.root / 'LICENSE').write_text('different content')
        with self.assertRaisesRegex(RuntimeError, '对应源码'):
            ci_package.verify_source(path)

    def test_corresponding_source_rejects_traversal_or_duplicates(self):
        for name in ('../outside', 'LICENSE'):
            path = self.work / 'bad.tar.gz'
            with tarfile.open(path, 'w:gz') as archive:
                for _ in range(2):
                    info = tarfile.TarInfo(name)
                    content = b'MIT fixture\n'
                    info.size = len(content)
                    archive.addfile(info, io.BytesIO(content))
            with self.subTest(name=name), self.assertRaisesRegex(RuntimeError, '对应源码'):
                ci_package.verify_source(path)

    def test_inputs_require_both_architectures_and_choose_same_source(self):
        for arch in ('arm64', 'arm64e'):
            self.artifact(arch)
        result = ci_package.prepare_inputs(self.work / 'input', self.descriptor)
        self.assertEqual(set(result['runtimes']), {'arm64', 'arm64e'})
        self.assertEqual(result['source'], self.work / 'input/arm64e/corresponding-source.tar.gz')

    def test_prebuilt_packaging_does_not_download_or_compile(self):
        prepared = {'runtimes': {'arm64e': self.work / 'runtime'}}
        with mock.patch.object(build_package, 'archives', side_effect=AssertionError('不能下载')), \
             mock.patch.object(build_package, 'build_engine', side_effect=AssertionError('不能编译')), \
             mock.patch.object(build_package, 'compile_runtime', side_effect=AssertionError('不能编译')), \
             mock.patch.object(build_package.tempfile, 'TemporaryDirectory', side_effect=RuntimeError('到达打包阶段')):
            with self.assertRaisesRegex(RuntimeError, '到达打包阶段'):
                build_package.main(prepared=prepared)

    def test_native_packaging_retains_environment_guards(self):
        with mock.patch.dict(os.environ, {'APELIN_PREFIX': '/var/jb'}), self.assertRaisesRegex(RuntimeError, '不一致'):
            build_package.required_environment()
        with mock.patch.dict(os.environ, {'APELIN_PACKAGE_DIR': ''}), self.assertRaisesRegex(RuntimeError, '未设置'):
            build_package.required_environment()

    def test_collect_release_requires_two_packages_and_emits_checksums(self):
        root = self.release()
        result = ci_package.collect_release(root)
        self.assertEqual(result['package_count'], 2)
        self.assertEqual(result['tag'], 'reverse-analysis-v0.1.3-ci.77')
        self.assertEqual(len((root / 'SHA256SUMS').read_text().splitlines()), 5)
        self.assertIn('version=0.1.3+ci.77', Path(self.env['GITHUB_OUTPUT']).read_text())

    def test_workflow_scopes_runner_context_to_steps(self):
        workflow = (ROOT / '.github/workflows/reverse-analysis.yml').read_text()
        for line in workflow.splitlines():
            if line.startswith('      ') and not line.startswith('        '):
                self.assertNotIn('${{ runner.', line, '作业级环境不能使用 runner 上下文')
        self.assertIn('          TMPDIR: ${{ runner.temp }}', workflow)
        self.assertIn('    needs: package', workflow)
        self.assertIn("          make_latest: 'false'", workflow)

    def test_collect_release_rejects_changed_package(self):
        root = self.release()
        next(root.glob('*.deb')).write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, '安装包摘要'):
            ci_package.collect_release(root)

    def test_collect_release_rejects_missing_architecture_slice(self):
        root = self.release()
        path = root / 'rootless-verification.json'
        report = json.loads(path.read_text())
        report['code_architectures'] = ['arm64']
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(RuntimeError, 'code_architectures'):
            ci_package.collect_release(root)

    def test_collect_release_rejects_mixed_corresponding_source(self):
        root = self.release()
        path = root / 'rootless-verification.json'
        report = json.loads(path.read_text())
        report['source_sha256'] = 'b' * 64
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(RuntimeError, '源码不一致'):
            ci_package.collect_release(root)

    def test_collect_release_rejects_missing_package(self):
        root = self.release()
        next(root.glob('*.deb')).unlink()
        with self.assertRaises(FileNotFoundError):
            ci_package.collect_release(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
