/* 仅供协议异常注入：不用于分析，不进入安装包。 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#ifndef FAULT_MODE
#error 必须明确指定异常模式
#endif
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--preflight")) return 0;
#if FAULT_MODE == 1
    char bytes[8192]; memset(bytes, 'd', sizeof(bytes));
    for (int i = 0; i < 140; i++) if (write(2, bytes, sizeof(bytes)) < 0) return 1;
#elif FAULT_MODE == 2
    unsigned char length[4] = {0, 16, 0, 1};
    if (write(1, length, sizeof(length)) != sizeof(length)) return 1;
#else
#error 不支持的异常模式
#endif
    for (;;) pause();
}
