/* 对真实分页实现做大集合、参数及输出边界测试；不依赖分析引擎。 */
#include "../../Extensions/AgentTools/ReverseAnalysis/Sources/FunctionPage.h"

int main(int argc, char **argv) {
    uint64_t count, offset, limit;
    if ((argc != 4 && argc != 5) || !ra_page_unsigned(argv[1], 1000000, &count) ||
        !ra_page_unsigned(argv[2], RAFunctionOffsetLimit, &offset) ||
        !ra_page_unsigned(argv[3], RAFunctionPageLimit, &limit) || !limit) return 64;
    RAFunctionRow *rows = calloc(count ? (size_t)count : 1, sizeof(*rows));
    if (!rows) return 70;
    char *large = NULL;
    const char *name = "函数_\"引用\"\\路径\n换行\t制表";
    if (argc == 5) {
        if (strcmp(argv[4], "oversized")) { free(rows); return 64; }
        large = malloc(RAFunctionPageBytes + 1);
        if (!large) { free(rows); return 70; }
        memset(large, 'x', RAFunctionPageBytes);
        large[RAFunctionPageBytes] = 0;
        name = large;
    }
    for (size_t i = 0; i < count; i++) {
        rows[i] = (RAFunctionRow){.address = UINT64_C(0x100000000) + (count - i - 1) * 4,
            .size = 64, .blocks = 2, .ordinal = i, .name = name};
    }
    ra_page_sort(rows, (size_t)count);
    char *page = ra_function_page_create(rows, (size_t)count, offset, limit);
    if (page) puts(page);
    free(rows); free(large);
    if (!page) return 75;
    free(page);
    return 0;
}
