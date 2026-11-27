/* 有界函数分页；仅序列化已选择的页，不构造完整 aflj 输出。 */
#ifndef RA_FUNCTION_PAGE_H
#define RA_FUNCTION_PAGE_H
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

enum { RAFunctionPageLimit = 500, RAFunctionPageBytes = 1024 * 1024 - 64 };
#define RAFunctionOffsetLimit UINT64_C(2147483647)

typedef struct {
    uint64_t address, size, blocks;
    size_t ordinal;
    const char *name;
    const void *context;
} RAFunctionRow;

typedef struct {
    char *bytes;
    size_t used, capacity;
    bool failed;
} RAPageWriter;

static bool ra_page_unsigned(const char *text, uint64_t maximum, uint64_t *value) {
    if (!text || !*text) return false;
    uint64_t parsed = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if (*p < '0' || *p > '9') return false;
        unsigned digit = *p - '0';
        if (digit > maximum || parsed > (maximum - digit) / 10) return false;
        parsed = parsed * 10 + digit;
    }
    *value = parsed;
    return true;
}

static int ra_page_compare(const void *left, const void *right) {
    const RAFunctionRow *a = left, *b = right;
    if (a->address != b->address) return a->address < b->address ? -1 : 1;
    return a->ordinal < b->ordinal ? -1 : a->ordinal != b->ordinal;
}

static void ra_page_sort(RAFunctionRow *rows, size_t count) {
    if (count > 1) qsort(rows, count, sizeof(*rows), ra_page_compare);
}

static void ra_page_append(RAPageWriter *writer, const char *bytes, size_t count) {
    if (writer->failed) return;
    if (writer->used >= writer->capacity || count >= writer->capacity - writer->used) {
        writer->failed = true;
        return;
    }
    memcpy(writer->bytes + writer->used, bytes, count);
    writer->used += count;
    writer->bytes[writer->used] = 0;
}

static void ra_page_text(RAPageWriter *writer, const char *text) {
    ra_page_append(writer, text, strlen(text));
}

static void ra_page_string(RAPageWriter *writer, const char *text) {
    static const char hex[] = "0123456789abcdef";
    ra_page_text(writer, "\"");
    for (const unsigned char *p = (const unsigned char *)text; *p && !writer->failed; p++) {
        if (*p == '"' || *p == '\\') {
            char escaped[2] = {'\\', (char)*p};
            ra_page_append(writer, escaped, sizeof(escaped));
        } else if (*p < 0x20) {
            char escaped[6] = {'\\', 'u', '0', '0', hex[*p >> 4], hex[*p & 15]};
            ra_page_append(writer, escaped, sizeof(escaped));
        } else {
            ra_page_append(writer, (const char *)p, 1);
        }
    }
    ra_page_text(writer, "\"");
}

/* rows 已按地址及原始顺序排序；页外条目的 name 可以为空。 */
static char *ra_function_page_create(const RAFunctionRow *rows, size_t count,
                                     uint64_t offset, uint64_t limit) {
    if (offset > RAFunctionOffsetLimit || !limit || limit > RAFunctionPageLimit || (count && !rows)) return NULL;
    char *output = calloc(RAFunctionPageBytes, 1);
    if (!output) return NULL;
    RAPageWriter writer = {output, 0, RAFunctionPageBytes, false};
    size_t start = offset < count ? (size_t)offset : count;
    size_t length = count - start < limit ? count - start : (size_t)limit;
    ra_page_text(&writer, "{\"functions\":[");
    for (size_t i = 0; i < length && !writer.failed; i++) {
        const RAFunctionRow *row = &rows[start + i];
        if (!row->name) { writer.failed = true; break; }
        if (i) ra_page_text(&writer, ",");
        char number[128];
        snprintf(number, sizeof(number), "{\"address\":\"0x%" PRIx64 "\",\"name\":", row->address);
        ra_page_text(&writer, number);
        ra_page_string(&writer, row->name);
        snprintf(number, sizeof(number), ",\"size\":%" PRIu64 ",\"blocks\":%" PRIu64 "}", row->size, row->blocks);
        ra_page_text(&writer, number);
    }
    char suffix[128];
    if (start + length < count) {
        snprintf(suffix, sizeof(suffix), "],\"total\":%zu,\"next_offset\":%zu}", count, start + length);
    } else {
        snprintf(suffix, sizeof(suffix), "],\"total\":%zu,\"next_offset\":null}", count);
    }
    ra_page_text(&writer, suffix);
    if (writer.failed) { free(output); return NULL; }
    return output;
}
#endif
