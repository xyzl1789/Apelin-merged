#!/usr/bin/env python3
"""构建契约测试；使用假编译器检查参数，不下载、不执行目标程序。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'Extensions/AgentTools/ReverseAnalysis/Scripts'
sys.path.insert(0, str(SCRIPTS))
import build_support as support
import ci_build


class BuildContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        base = ROOT / 'build/reverse-analysis/build-contract-tests'
        base.mkdir(parents=True, exist_ok=True)
        cls.scratch = tempfile.TemporaryDirectory(dir=base)
        cls.base = Path(cls.scratch.name)
        cls.fake = cls.base / 'bin'
        cls.fake.mkdir()
        compiler = cls.fake / 'clang'
        compiler.write_text(
            '#!/usr/bin/env python3\nimport json, os, pathlib, sys\n'
            'pathlib.Path(os.environ["RA_TEST_LOG"]).write_text(json.dumps({\n'
            '"args": sys.argv[1:], "sdk": os.environ.get("SDKROOT"),\n'
            '"ios_min": os.environ.get("IPHONEOS_DEPLOYMENT_TARGET")}))\n'
            'if os.environ.get("RA_TEST_FAIL"): sys.exit(7)\n'
            'if os.environ.get("RA_TEST_LINK"):\n'
            '    pathlib.Path(sys.argv[sys.argv.index("-o") + 1]).write_bytes(b"test")\n')
        compiler.chmod(0o755)
        signer = cls.fake / 'ldid'
        signer.write_text('#!/usr/bin/env python3\nimport os, pathlib, sys\n'
                          'pathlib.Path(os.environ["RA_TEST_SIGN"]).write_text("\\n".join(sys.argv[1:]))\n')
        signer.chmod(0o755)
        cls.ios = cls.base / 'iPhoneOS.sdk'
        cls.macos = cls.base / 'MacOSX.sdk'
        cls.ios.mkdir()
        cls.macos.mkdir()

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=self.base)
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.env = {**os.environ, 'PATH': str(self.fake) + ':' + os.environ['PATH'],
                    'APELIN_PROJECT_ROOT': os.environ['APELIN_PROJECT_ROOT'],
                    'APELIN_REVERSE_ARCH': 'arm64e',
                    'APELIN_REVERSE_ENTITLEMENTS': 'approved.plist',
                    'SDKROOT': str(self.ios), 'RA_HOST_SDKROOT': str(self.macos),
                    'APELIN_REVERSE_HOST_SDKROOT': str(self.macos),
                    'RA_CROSS_COMPILE': '0', 'RA_TEST_LOG': str(self.work / 'compiler.json'),
                    'RA_TEST_SIGN': str(self.work / 'signature.txt')}
        for key in ('RA_TEST_LINK', 'RA_TEST_FAIL'):
            self.env.pop(key, None)

    def wrapper(self, name, args, expected=0):
        result = subprocess.run(['bash', str(SCRIPTS / 'bin' / name), *args],
                                env=self.env, cwd=self.work, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stderr.decode(errors='replace'))
        log = Path(self.env['RA_TEST_LOG'])
        return json.loads(log.read_text()) if log.exists() else None

    def configured(self):
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(support.shutil, 'which', return_value='/tool/ar'):
            return support.environment('arm64e', self.base)

    def test_native_compiler_keeps_prepared_toolchain(self):
        data = self.wrapper('reverse-cc', ['-c', 'sample.c'])
        self.assertIn('arm64e', data['args'])
        self.assertNotIn('-target', data['args'])
        self.assertFalse(Path(self.env['RA_TEST_SIGN']).exists())

    def test_cross_compiler_selects_ios_explicitly(self):
        self.env['RA_CROSS_COMPILE'] = '1'
        data = self.wrapper('reverse-cc', ['-c', 'sample.c'])
        self.assertIn('arm64e-apple-ios16.0', data['args'])
        self.assertEqual(data['args'][data['args'].index('-isysroot') + 1], str(self.ios))

    def test_cross_arm64_is_not_arm64e(self):
        self.env.update(RA_CROSS_COMPILE='1', APELIN_REVERSE_ARCH='arm64')
        data = self.wrapper('reverse-cc', ['-arch', 'arm64', '-c', 'sample.c'])
        self.assertIn('arm64-apple-ios16.0', data['args'])
        self.assertEqual(data['args'].count('-arch'), 1)

    def test_host_generator_does_not_inherit_ios_sdk_or_minimum(self):
        self.env.update(RA_CROSS_COMPILE='1', IPHONEOS_DEPLOYMENT_TARGET='16.0')
        data = self.wrapper('reverse-host-cc', ['-O2', '-c', 'generator.c'])
        self.assertEqual(data['sdk'], str(self.macos))
        self.assertIsNone(data['ios_min'])
        self.assertNotIn('-target', data['args'])
        self.assertNotIn('-arch', data['args'])
        self.assertNotIn('-DAPPLE_SDK_IPHONEOS=1', data['args'])
        self.assertFalse(Path(self.env['RA_TEST_SIGN']).exists())

    def test_native_environment_uses_native_host_compiler(self):
        self.assertEqual(self.configured()['HOST_CC'], 'reverse-cc')

    def test_cross_environment_separates_all_host_variables(self):
        self.env['RA_CROSS_COMPILE'] = '1'
        configured = self.configured()
        for key in ('HOST_CC', 'HOSTCC', 'CC_FOR_BUILD'):
            self.assertEqual(configured[key], 'reverse-host-cc')
        self.assertEqual(configured['CC'], 'reverse-cc')
        self.assertNotIn('-arch', configured['HOST_CFLAGS'])
        self.assertNotIn('iphoneos', configured['HOST_CFLAGS'])

    def test_cross_environment_rejects_same_sdk(self):
        self.env.update(RA_CROSS_COMPILE='1', RA_HOST_SDKROOT=str(self.ios))
        with self.assertRaisesRegex(RuntimeError, '不得相同'):
            self.configured()

    def test_cross_environment_rejects_missing_host_sdk(self):
        self.env['RA_CROSS_COMPILE'] = '1'
        self.env.pop('RA_HOST_SDKROOT')
        with self.assertRaisesRegex(RuntimeError, 'RA_HOST_SDKROOT'):
            self.configured()

    def test_cross_wrapper_rejects_empty_sdk(self):
        self.env.update(RA_CROSS_COMPILE='1', SDKROOT='')
        self.assertIsNone(self.wrapper('reverse-cc', ['-c', 'sample.c'], expected=1))

    def test_host_wrapper_rejects_empty_sdk(self):
        self.env['APELIN_REVERSE_HOST_SDKROOT'] = ''
        self.assertIsNone(self.wrapper('reverse-host-cc', ['-c', 'sample.c'], expected=1))

    def test_invalid_cross_mode_fails_closed(self):
        self.env['RA_CROSS_COMPILE'] = 'yes'
        with self.assertRaisesRegex(RuntimeError, '只能为'):
            self.configured()
        self.assertIsNone(self.wrapper('reverse-cc', ['-c', 'sample.c'], expected=1))

    def test_rootfs_paths_remain_translated(self):
        data = self.wrapper('reverse-cc', ['-I/rootfs/test/include', '-L/rootfs/test/lib', '-c', '/rootfs/test/sample.c'])
        for value in ('-I/test/include', '-L/test/lib', '/test/sample.c'):
            self.assertIn(value, data['args'])

    def test_successful_link_is_signed(self):
        self.env['RA_TEST_LINK'] = '1'
        self.wrapper('reverse-cc', ['sample.c', '-o', 'result'])
        self.assertEqual(Path(self.env['RA_TEST_SIGN']).read_text(), '-Sapproved.plist\nresult')

    def test_failed_link_is_not_signed(self):
        self.env.update(RA_TEST_LINK='1', RA_TEST_FAIL='1')
        self.wrapper('reverse-cc', ['sample.c', '-o', 'result'], expected=7)
        self.assertFalse(Path(self.env['RA_TEST_SIGN']).exists())

    def test_ios_load_commands_accept_numeric_and_named_platform(self):
        for text in (' platform 2\n', ' platform IOS\n', 'cmd LC_VERSION_MIN_IPHONEOS\n'):
            self.assertTrue(support.is_ios_header(text))
        for text in (' platform 1\n', ' platform MACOS\n', ' platform IOSSIMULATOR\n', ' platform 20\n'):
            self.assertFalse(support.is_ios_header(text))

    def test_runtime_verification_checks_both_binaries_without_execution(self):
        runtime = self.work / 'runtime'
        data = runtime / 'sleigh'
        data.mkdir(parents=True)
        hashes = {}
        for number in range(8):
            path = data / ('data-' + str(number))
            path.write_bytes(bytes([number]))
            hashes[path.name] = support.sha(path)
        (runtime / 'data-sha256.json').write_text(json.dumps(hashes))
        with mock.patch.object(ci_build, 'check_binary') as check, mock.patch.object(ci_build.subprocess, 'Popen', side_effect=AssertionError('不允许执行目标程序')):
            report = ci_build.verify_runtime(runtime, 'arm64')
        self.assertEqual(check.call_args_list, [mock.call(runtime / name, ['arm64']) for name in ci_build.NAMES])
        self.assertFalse(report['ios_binaries_executed'])
        self.assertFalse(report['device_acceptance'])
        (data / 'data-0').write_bytes(b'changed')
        with mock.patch.object(ci_build, 'check_binary'), self.assertRaisesRegex(RuntimeError, '摘要'):
            ci_build.verify_runtime(runtime, 'arm64')

    def test_finalize_strips_then_resigns_each_binary(self):
        with mock.patch.object(ci_build.subprocess, 'run') as run:
            ci_build.finalize_runtime(self.work)
        expected = []
        for name in ci_build.NAMES:
            path = self.work / name
            expected.extend([mock.call(['strip', '-x', support.tool_path(path)], check=True),
                             mock.call(['ldid', '-S' + str(support.EXT / 'Packaging/entitlements.plist'), str(path)], check=True)])
        self.assertEqual(run.call_args_list, expected)

    def test_finalize_failure_does_not_sign_invalid_output(self):
        with mock.patch.object(ci_build.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'strip')) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                ci_build.finalize_runtime(self.work)
        self.assertEqual(run.call_count, 1)

    def test_host_generator_rejects_ios_platform(self):
        with mock.patch.object(ci_build.subprocess, 'check_output', return_value=b' platform 2\n'):
            with self.assertRaisesRegex(RuntimeError, 'macOS'):
                ci_build.verify_host_generator(self.work)
        with mock.patch.object(ci_build.subprocess, 'check_output', return_value=b' platform MACOS\n'):
            self.assertTrue(ci_build.verify_host_generator(self.work)['separate_from_ios_runtime'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
