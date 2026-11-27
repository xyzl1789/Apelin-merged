#!/usr/bin/env python3
"""大体积真实样本的有界分页与四项协议验收；不安装、不执行样本。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    state = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            state.update(block)
    return state.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--arch', required=True, choices=['arm64', 'arm64e'])
    parser.add_argument('--report', default='build/reverse-analysis/results/large-sample-paging.json')
    args = parser.parse_args()
    paths = {}
    for key in ('runtime', 'binary', 'report'):
        path = (ROOT / getattr(args, key)).resolve()
        if not path.is_relative_to(ROOT):
            raise RuntimeError('测试路径必须在项目内：' + key)
        paths[key] = path
    os.environ['RA_RUNTIME'] = str(paths['runtime'])
    from verify_extension import Client, native, require, gone, wait_until

    binary = paths['binary']
    before = digest(binary)
    report = {'scope': '独立原生协议进程；不代表主应用升级后已完成真实工具调用验收',
              'sample': str(binary.relative_to(ROOT)), 'runtime': str(paths['runtime'].relative_to(ROOT)),
              'bytes': binary.stat().st_size, 'sha256': before, 'arch': args.arch, 'passed': False,
              'source_sha256': {name: digest(ROOT / 'Extensions/AgentTools/ReverseAnalysis/Sources' / name)
                                for name in ('Worker.c', 'Analysis.m', 'FunctionPage.h')}}
    started = time.monotonic()
    paths['report'].parent.mkdir(parents=True, exist_ok=True)
    try:
        all_rows, pages, pids = [], [], set()
        with Client() as client:
            def request(tool='analyze_functions', **extra):
                identifier = client.start(tool, arch=args.arch, binary=native(binary), timeout_seconds=60, **extra)
                response = client.receive(timeout=65)
                require(response.get('requestID') == identifier and response.get('type') == 'result',
                        '大样本调用失败：' + str(response))
                result = json.loads(response['content'][0]['text'])
                require(result['meta']['sha256'] == before, '快照摘要不符')
                pids.add(result['meta']['pid'])
                return result

            first = request(limit=1)
            report['engine_sha256'] = first['meta']['engine_sha256']
            report['data_sha256'] = first['meta']['data_sha256']
            total = first['data']['total']
            require(total > 500 and len(first['data']['functions']) == 1, '样本不足以覆盖多页场景')
            require(not first['meta']['cache_hit'], '首个调用不应命中缓存')
            offset = 0
            while offset is not None:
                result = request(offset=offset, limit=500)
                page = result['data']
                require(page['total'] == total, '跨页函数总数变化')
                expected = min(500, total - offset)
                require(len(page['functions']) == expected, '页长不符')
                next_offset = offset + expected if offset + expected < total else None
                require(page['next_offset'] == next_offset, '分页游标不符')
                all_rows.extend(page['functions'])
                pages.append({'offset': offset, 'count': expected,
                              'json_bytes': len(json.dumps(result, ensure_ascii=False).encode()),
                              'cache_hit': result['meta']['cache_hit'], 'pid': result['meta']['pid']})
                offset = next_offset
            addresses = [int(row['address'], 16) for row in all_rows]
            require(len(all_rows) == total and addresses == sorted(addresses), '跨页次序或总数不符')
            require(len(set(addresses)) == total, '分页重复函数入口')
            require(all_rows[0] == first['data']['functions'][0], '小页与大页结果不一致')
            for offset in (total, total + 1, 2147483647):
                terminal = request(offset=offset, limit=1)['data']
                require(terminal == {'functions': [], 'total': total, 'next_offset': None}, '越界页未终止')
            with binary.open('rb') as stream:
                client.attach('large-sample', [stream.fileno()])
                identifier = client.start(arch=args.arch, binary='descriptor-only', limit=1, timeout_seconds=60,
                    attachments=[{'id': 'large-sample', 'argument': 'binary', 'byteCount': binary.stat().st_size}])
                response = client.receive(timeout=65)
                require(response.get('type') == 'result' and response.get('requestID') == identifier, '大样本附件失败')
                attached = json.loads(response['content'][0]['text'])
                require(attached['data'] == first['data'] and attached['meta']['cache_hit'], '路径与附件结果不一致')

            candidate = next(row for row in all_rows if 8 <= row['size'] <= 128 and 1 <= row['blocks'] <= 4
                             and not row['name'].startswith(('sym.imp.', 'imp.')))
            address = candidate['address']
            graph = request('analyze_cfg', address=address)['data']
            incoming = request('analyze_references', address=address, direction='in')['data']
            outgoing = request('analyze_references', address=address, direction='out')['data']
            code = request('decompile_function', address=address)['data']
            require(isinstance(graph, list) and graph and graph[0].get('blocks'), 'CFG 缺少基本块')
            require(isinstance(incoming, list) and isinstance(outgoing, list), '引用结果类型错误')
            require(code.get('code') and code.get('annotations') and code.get('pcode_ops'), '缺少真实反编译证据')
            report.update(total_functions=total, pages=pages, worker_pids=sorted(pids),
                          attachment_matches_path=True, terminal_offsets_checked=[total, total + 1, 2147483647],
                          selected_function=candidate,
                          tools={'cfg_blocks': len(graph[0]['blocks']), 'incoming_references': len(incoming),
                                 'outgoing_references': len(outgoing), 'pseudocode_bytes': len(code['code'].encode()),
                                 'has_annotations': True, 'has_pcode': True})
            identifier = client.start(arch=args.arch, binary=native(binary), limit=1, timeout_seconds=0.001)
            rejected = client.receive(timeout=5)
            require(rejected.get('requestID') == identifier and rejected.get('error', {}).get('code') == 'timeout',
                    '短时限未正确拒绝')
            recovered = request(limit=1)
            require(recovered['data'] == first['data'], '超时后恢复结果变化')
            report['timeout_recovery'] = True
        wait_until(lambda: all(gone(pid) for pid in client.pids), seconds=5)
        report['all_worker_groups_reaped'] = True
        report['passed'] = True
    except BaseException as error:
        report['failure'] = str(error)
        raise
    finally:
        report['input_unchanged'] = digest(binary) == before
        report['elapsed_seconds'] = round(time.monotonic() - started, 3)
        if not report['input_unchanged']:
            report['passed'] = False
        paths['report'].write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({key: report[key] for key in ('passed', 'input_unchanged', 'elapsed_seconds')}, ensure_ascii=False))
    require(report['input_unchanged'], '分析修改了输入样本')


if __name__ == '__main__':
    main()
