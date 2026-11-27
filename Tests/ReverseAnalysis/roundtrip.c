/* 对反编译结果回编译后，独立核对三类逻辑；不链接原样本函数。 */
#include <stdint.h>
#include <stdio.h>

int fixture_value(int64_t value);
int fixture_branch(int64_t value);
int fixture_caller(int64_t value);

int main(void) {
    unsigned cases = 0;
    for (int64_t input = -1000; input <= 1000; ++input) {
        int expected_value = (int)(input * 3 + 7);
        int expected_branch = input > 9 ? expected_value : input < 0 ? (int)-input : (int)input + 11;
        if (fixture_value(input) != expected_value ||
            fixture_branch(input) != expected_branch ||
            fixture_caller(input) != expected_value + expected_branch) {
            fprintf(stderr, "伪代码对照不符，输入 %lld\n", (long long)input);
            return 1;
        }
        ++cases;
    }
    printf("{\"inputs\":%u,\"function_checks\":%u,\"passed\":true}\n", cases, cases * 3);
    return 0;
}
