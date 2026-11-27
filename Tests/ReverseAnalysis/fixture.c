#include <stdio.h>

/* 已知算术逻辑，用于核对真正的反编译结果。 */
__attribute__((noinline, used)) int fixture_value(int value) {
    return value * 3 + 7;
}

/* 保留显式基本块，供 CFG 条件分支验收。 */
__attribute__((noinline, used, optnone)) int fixture_branch(int value) {
    if (value > 9) {
        return fixture_value(value);
    }
    if (value < 0) {
        return -value;
    }
    return value + 11;
}

/* 保留两条可追踪的函数调用。 */
__attribute__((noinline, used)) int fixture_caller(int value) {
    return fixture_value(value) + fixture_branch(value);
}

int main(void) {
    volatile int small = 3;
    volatile int negative = -4;
    volatile int large = 20;
    printf("{\"value\":%d,\"small\":%d,\"negative\":%d,\"large\":%d,\"caller\":%d}\n",
           fixture_value(small), fixture_branch(small), fixture_branch(negative),
           fixture_branch(large), fixture_caller(small));
    return 0;
}
