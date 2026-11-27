/* 隔离原型：仅接受固定操作；没有对外的引擎命令参数。 */
#include <r_core.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern RCorePlugin r_core_plugin_r2ghidra;
enum { OUTPUT_LIMIT = 1024 * 1024, LINE_LIMIT = 96 };
static FILE *protocol;

static bool frame(const char *prefix, const char *data, const char *suffix) {
    size_t a = strlen(prefix), b = strlen(data), c = strlen(suffix);
    uint32_t length = (uint32_t)(a + b + c);
    unsigned char header[4] = {length >> 24, length >> 16, length >> 8, length};
    return fwrite(header, 1, 4, protocol) == 4 &&
        fwrite(prefix, 1, a, protocol) == a &&
        fwrite(data, 1, b, protocol) == b &&
        fwrite(suffix, 1, c, protocol) == c && fflush(protocol) == 0;
}

static bool failure(const char *code) {
    return frame("{\"ok\":false,\"error\":\"", code, "\"}");
}

static bool success(const char *data) {
    if (strnlen(data, OUTPUT_LIMIT + 1) > OUTPUT_LIMIT - 32) {
        return failure("output_limit");
    }
    return frame("{\"ok\":true,\"data\":", data, "}");
}

static bool address_value(const char *text, ut64 *value) {
    size_t length = text ? strlen(text) : 0;
    if (length < 3 || length > 18 || text[0] != '0' || text[1] != 'x') return false;
    for (size_t i = 2; i < length; i++) {
        char ch = text[i];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') ||
              (ch >= 'A' && ch <= 'F'))) return false;
    }
    *value = (ut64)strtoull(text + 2, NULL, 16);
    return true;
}

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    /* 引擎及插件的诊断只能去 stderr，不得污染带长度的响应通道。 */
    protocol = fdopen(dup(STDOUT_FILENO), "wb");
    if (!protocol || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 70;
    RCore *core = r_core_new();
    if (!core) return 70;
    r_cons_set_interactive(core->cons, false);
    r_config_set_b(core->config, "scr.interactive", false);
    r_config_set_i(core->config, "scr.color", 0);
    r_config_set_b(core->config, "cfg.fortunes", false);
    r_config_set_b(core->config, "bin.relocs.apply", true);
    if (!r_core_plugin_add(core->rcmd, &r_core_plugin_r2ghidra)) {
        failure("engine_init");
        r_core_free(core);
        return 70;
    }
    if (!r_core_file_open(core, argv[1], R_PERM_R, 0) ||
        !r_core_bin_load(core, argv[1], UT64_MAX)) {
        failure("invalid_binary");
        r_core_free(core);
        return 66;
    }
    char *analysis = r_core_cmd_str(core, "aaa");
    free(analysis);
    if (!success("{\"ready\":true,\"analysis_runs\":1}")) {
        r_core_free(core);
        return 74;
    }
    for (;;) {
        char line[LINE_LIMIT];
        size_t used = 0;
        bool bad = false;
        int ch;
        while ((ch = fgetc(stdin)) != EOF && ch != '\n') {
            if (!ch || used + 1 >= sizeof(line)) bad = true;
            else line[used++] = (char)ch;
        }
        if (ch == EOF) break;
        line[used] = 0;
        if (bad) {
            if (!failure("invalid_request")) break;
            continue;
        }
        char *state = NULL;
        char *op = strtok_r(line, " ", &state);
        char *arg = strtok_r(NULL, " ", &state);
        char *extra = strtok_r(NULL, " ", &state);
        const char *format = NULL;
        ut64 address = 0;
        if (op && !strcmp(op, "functions") && !arg) format = "aflj";
        else if (op && arg && !extra && address_value(arg, &address)) {
            if (!strcmp(op, "cfg")) format = "agfj @ 0x%" PRIx64;
            else if (!strcmp(op, "refs_in")) format = "axtj @ 0x%" PRIx64;
            else if (!strcmp(op, "refs_out")) format = "axffj @ 0x%" PRIx64;
            else if (!strcmp(op, "decompile")) format = "pdgj @ 0x%" PRIx64;
            if (format && !r_anal_get_function_at(core->anal, address)) {
                if (!failure("function_not_found")) break;
                continue;
            }
        }
        if (!format) {
            if (!failure("invalid_request")) break;
            continue;
        }
        char command[80];
        snprintf(command, sizeof(command), format, (uint64_t)address);
        char *result = r_core_cmd_str(core, command);
        bool sent = result && *result ? success(result) : failure("analysis_failed");
        free(result);
        if (!sent) break;
    }
    r_core_free(core);
    fclose(protocol);
    return 0;
}
