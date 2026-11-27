#!/usr/bin/env python3
"""从随包对应源码离线重建独立工作进程，不生成或安装软件包。"""
import argparse
from build_support import archives, build_engine, compile_runtime, relative


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--arch', required=True, choices=['arm64', 'arm64e'])
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    archives()
    base, r2, ghidra, sleigh, env = build_engine(args.arch, args.jobs)
    runtime = base / 'runtime'
    compile_runtime(args.arch, runtime, r2, ghidra, sleigh, env)
    print('独立原生程序和语言数据已生成：' + relative(runtime))


if __name__ == '__main__':
    main()
