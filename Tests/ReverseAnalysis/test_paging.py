#!/usr/bin/env python3
"""真实 C 分页实现回归；与引擎语义及主应用验收分开计数。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
EXT = ROOT / 'Extensions/AgentTools/ReverseAnalysis'


def is_ios_device_runtime():
    """只有在 iOS 设备及 iPhoneOS SDK 下才交叉编译并签名测试程序。"""
    sdk = Path(os.environ.get('SDKROOT', ''))
    return (sys.platform == 'darwin' and sdk.name.lower().startswith('iphoneos')
            and bool(os.environ.get('APELIN_TOOLCHAIN_BIN')))


class FunctionPagingTests(unittest.TestCase):
    def test_linux_ci_project_root_does_not_enable_ios_cross_compile(self):
        with mock.patch.object(sys, 'platform', 'linux'), mock.patch.dict(
                os.environ, {'APELIN_PROJECT_ROOT': '/workspace', 'SDKROOT': ''}, clear=True):
            self.assertFalse(is_ios_device_runtime())

    def test_ios_device_sdk_enables_arm64_signing_mode(self):
        with mock.patch.object(sys, 'platform', 'darwin'), mock.patch.dict(
                os.environ, {'APELIN_PROJECT_ROOT': '/project', 'SDKROOT': '/registered/iphoneos17.4-sdk',
                            'APELIN_TOOLCHAIN_BIN': '/toolchain/bin'}, clear=True):
            self.assertTrue(is_ios_device_runtime())

    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            raise RuntimeError('有界分页回归缺少 C 编译器')
        cache = ROOT / 'build/reverse-analysis/paging-tests'
        cache.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix='native-', dir=cache)
        cls.binary = Path(cls.temporary.name) / 'paging-fixture'
        args = [compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror']
        if is_ios_device_runtime():
            args += ['-arch', 'arm64']
        args += ['Tests/ReverseAnalysis/paging_fixture.c', '-o', str(cls.binary.relative_to(ROOT))]
        subprocess.run(args, cwd=ROOT, check=True, capture_output=True)
        if is_ios_device_runtime():
            subprocess.run(['ldid', '-STests/ReverseAnalysis/Tool.entitlements', str(cls.binary.relative_to(ROOT))],
                           cwd=ROOT, check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_page(self, *args):
        return subprocess.run(['./' + str(self.binary.relative_to(ROOT)), *map(str, args)],
                              cwd=ROOT, capture_output=True, text=True, timeout=10)

    def page(self, *args):
        result = self.run_page(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_hundred_thousand_functions_return_one_small_page(self):
        result = self.run_page(100000, 0, 1)
        self.assertEqual(result.returncode, 0)
        self.assertLess(len(result.stdout.encode()), 1024)
        page = json.loads(result.stdout)
        self.assertEqual((page['total'], page['next_offset']), (100000, 1))
        self.assertEqual([x['address'] for x in page['functions']], ['0x100000000'])

    def test_pages_are_sorted_without_missing_or_duplicate_entries(self):
        pages = [self.page(1003, start, 500) for start in (0, 500, 1000)]
        self.assertEqual([len(p['functions']) for p in pages], [500, 500, 3])
        self.assertEqual([p['next_offset'] for p in pages], [500, 1000, None])
        addresses = [int(x['address'], 16) for p in pages for x in p['functions']]
        self.assertEqual(addresses, list(range(0x100000000, 0x100000000 + 1003 * 4, 4)))

    def test_empty_and_out_of_range_pages_are_terminal(self):
        for count, offset in ((0, 0), (5, 5), (5, 2147483647)):
            self.assertEqual(self.page(count, offset, 1), {'functions': [], 'total': count, 'next_offset': None})

    def test_unicode_quotes_backslashes_and_controls_roundtrip(self):
        row = self.page(1, 0, 1)['functions'][0]
        self.assertEqual(row['name'], '函数_"引用"\\路径\n换行\t制表')
        self.assertEqual((row['size'], row['blocks']), (64, 2))

    def test_decimal_bounds_reject_signs_suffixes_and_overflow(self):
        for offset, limit in (('-1', '1'), ('+1', '1'), ('1x', '1'), ('2147483648', '1'),
                              ('18446744073709551616', '1'), ('0', '0'), ('0', '501'), ('0', '-1')):
            self.assertEqual(self.run_page('10', offset, limit).returncode, 64)

    def test_oversized_selected_name_fails_without_partial_json(self):
        result = self.run_page(1, 0, 1, 'oversized')
        self.assertEqual(result.returncode, 75)
        self.assertEqual(result.stdout, '')

    def test_worker_never_serializes_the_full_function_list(self):
        worker = (EXT / 'Sources/Worker.c').read_text()
        analysis = (EXT / 'Sources/Analysis.m').read_text()
        self.assertNotIn('"aflj"', worker)
        self.assertIn('ra_function_page_create(rows, count, offset, limit)', worker)
        self.assertIn('@"functions %lu %lu"', analysis)
        self.assertNotIn('sortedArrayUsingComparator', analysis)
        self.assertIn('函数分页边界错误', analysis)


if __name__ == '__main__':
    unittest.main(verbosity=2)
