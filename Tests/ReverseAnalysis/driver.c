/* 独立试验驱动：仅供自有样本验收，不是对外的任意命令工具。 */
#include <r_core.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern RCorePlugin r_core_plugin_r2ghidra;

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "用法：原生试验驱动 <自有样本> <验收命令>\n");
        return 64;
    }
    RCore *core = r_core_new();
    if (!core) {
        return 70;
    }
    r_cons_set_interactive(core->cons, false);
    r_config_set_b(core->config, "scr.interactive", false);
    r_config_set_i(core->config, "scr.color", 0);
    r_config_set_b(core->config, "cfg.fortunes", false);
    r_config_set_b(core->config, "bin.relocs.apply", true);
    if (!r_core_plugin_add(core->rcmd, &r_core_plugin_r2ghidra)) {
        fprintf(stderr, "Ghidra 静态插件注册失败\n");
        r_core_free(core);
        return 70;
    }
    if (!r_core_file_open(core, argv[1], R_PERM_R, 0) ||
        !r_core_bin_load(core, argv[1], UT64_MAX)) {
        fprintf(stderr, "无法只读打开自有样本\n");
        r_core_free(core);
        return 66;
    }
    char *analysis = r_core_cmd_str(core, "aaa");
    free(analysis);
    char *result = r_core_cmd_str(core, argv[2]);
    int status = result ? 0 : 70;
    if (result) {
        fputs(result, stdout);
        free(result);
    }
    r_core_free(core);
    return status;
}
