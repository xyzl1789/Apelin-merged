/* 独立的固定操作工作进程。引擎及插件只链接到这个程序。 */
#include <r_core.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

extern RCorePlugin r_core_plugin_r2ghidra;
enum { OUTPUT_LIMIT = 1024 * 1024, LINE_LIMIT = 96 };
static FILE *protocol;
static pid_t expected_parent;
/* 这是采样后终止，不是假称内核强制的内存硬限额。 */
static void *watch_parent_and_memory(void *unused) {
    (void)unused;
    for (;;) {
        struct rusage usage;
        if (getppid() != expected_parent) _exit(76);
        if (getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss > 512L * 1024 * 1024) _exit(75);
        usleep(50000);
    }
    return NULL;
}
static bool frame(const char *prefix, const char *data, const char *suffix) {
    size_t a = strlen(prefix), b = strlen(data), c = strlen(suffix);
    uint32_t length = (uint32_t)(a + b + c);
    unsigned char header[4] = {length >> 24, length >> 16, length >> 8, length};
    return fwrite(header, 1, 4, protocol) == 4 && fwrite(prefix, 1, a, protocol) == a &&
        fwrite(data, 1, b, protocol) == b && fwrite(suffix, 1, c, protocol) == c && fflush(protocol) == 0;
}
static bool failure(const char *code) { return frame("{\"ok\":false,\"error\":\"", code, "\"}"); }
static bool success(const char *data) {
    if (strnlen(data, OUTPUT_LIMIT + 1) > OUTPUT_LIMIT - 32) return failure("output_limit");
    return frame("{\"ok\":true,\"data\":", data, "}");
}
static bool address_value(const char *text, ut64 *value) {
    size_t length = text ? strlen(text) : 0;
    if (length < 3 || length > 18 || text[0] != '0' || text[1] != 'x') return false;
    for (size_t i = 2; i < length; i++) {
        char ch = text[i];
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) return false;
    }
    *value = (ut64)strtoull(text + 2, NULL, 16); return true;
}
int main(int argc, char **argv) {
    // 仅让系统完成首次执行元数据处理；不打开样本、不初始化引擎。
    if (argc == 2 && !strcmp(argv[1], "--preflight")) return 0;
    const char *parent = getenv("RA_PARENT_PID");
    if (argc != 2 || strcmp(argv[1], "/dev/fd/4") || !parent || (fcntl(4, F_GETFL) & O_ACCMODE) != O_RDONLY) return 64;
    char *end = NULL; long value = strtol(parent, &end, 10);
    if (!*parent || *end || value <= 1 || value != getppid()) return 64;
    expected_parent = (pid_t)value;
    pthread_t watcher;
    if (pthread_create(&watcher, NULL, watch_parent_and_memory, NULL)) return 70;
    pthread_detach(watcher);
    struct rlimit cpu = {60, 61};
    if (setrlimit(RLIMIT_CPU, &cpu)) return 70;
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
        failure("engine_init"); r_core_free(core); return 70;
    }
    /* 引擎不兼容 iOS 的 /dev/fd 文件加载，故将只读 fd 复制到私有 malloc I/O。
       这里只写引擎的私有副本，原文件与传入描述符从未以写模式打开。 */
    struct stat input;
    if (fstat(4, &input) || !S_ISREG(input.st_mode) || input.st_size < 32 || input.st_size > 48 * 1024 * 1024) {
        failure("invalid_binary"); r_core_free(core); return 66;
    }
    char uri[64]; snprintf(uri, sizeof(uri), "malloc://%" PRIu64, (uint64_t)input.st_size);
    RIODesc *memory = r_core_file_open(core, uri, R_PERM_RW, 0);
    bool copied = memory != NULL;
    unsigned char bytes[65536];
    for (off_t offset = 0; copied && offset < input.st_size;) {
        ssize_t count = pread(4, bytes, (size_t)R_MIN((off_t)sizeof(bytes), input.st_size - offset), offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || r_io_desc_write_at(memory, (ut64)offset, bytes, (int)count) != count) { copied = false; break; }
        offset += count;
    }
    close(4);
    if (memory) memory->perm = R_PERM_R;
    if (!copied || !r_core_bin_load(core, uri, UT64_MAX)) {
        failure("invalid_binary"); r_core_free(core); return 66;
    }
    char *analysis = r_core_cmd_str(core, "aaa"); free(analysis);
    if (!success("{\"ready\":true,\"analysis_runs\":1}")) { r_core_free(core); return 74; }
    for (;;) {
        char line[LINE_LIMIT]; size_t used = 0; bool bad = false; int ch;
        while ((ch = fgetc(stdin)) != EOF && ch != '\n') {
            if (!ch || used + 1 >= sizeof(line)) bad = true;
            else line[used++] = (char)ch;
        }
        if (ch == EOF) break;
        line[used] = 0;
        if (bad) { if (!failure("invalid_request")) break; continue; }
        char *state = NULL, *op = strtok_r(line, " ", &state), *arg = strtok_r(NULL, " ", &state), *extra = strtok_r(NULL, " ", &state);
        const char *format = NULL; ut64 address = 0;
        if (op && !strcmp(op, "functions") && !arg) format = "aflj";
        else if (op && arg && !extra && address_value(arg, &address)) {
            if (!strcmp(op, "cfg")) format = "agfj @ 0x%" PRIx64;
            else if (!strcmp(op, "refs_in")) format = "axtj @ 0x%" PRIx64;
            else if (!strcmp(op, "refs_out")) format = "axffj @ 0x%" PRIx64;
            else if (!strcmp(op, "decompile")) format = "pdgj @ 0x%" PRIx64;
            if (format && !r_anal_get_function_at(core->anal, address)) { if (!failure("function_not_found")) break; continue; }
        }
        if (!format) { if (!failure("invalid_request")) break; continue; }
        char command[80]; snprintf(command, sizeof(command), format, (uint64_t)address);
        if (!strcmp(op, "decompile")) { fprintf(stderr, "逆向反编译开始 pid=%d\n", getpid()); fflush(stderr); }
        char *result = r_core_cmd_str(core, command);
        bool sent = result && *result ? success(result) : failure("analysis_failed"); free(result);
        if (!sent) break;
    }
    r_core_free(core); fclose(protocol); return 0;
}
