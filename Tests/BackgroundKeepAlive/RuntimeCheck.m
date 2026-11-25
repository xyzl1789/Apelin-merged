#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>

// 与 Swift 桥接一样，使用经过签名检查的 IMP 和原始对象指针。
typedef void *(*Allocate)(const void *, SEL);
typedef void *(*Initialize)(void *, SEL, int32_t, uint32_t, uint32_t, const void *, const void *);
typedef bool (*IsValid)(const void *, SEL);
typedef void (*Invalidate)(const void *, SEL);

static BOOL matches(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments.count) return NO;
    char *type = method_copyReturnType(method);
    BOOL same = type && strcmp(type, result) == 0;
    free(type);
    if (!same) return NO;
    for (unsigned int i = 0; i < arguments.count; ++i) {
        type = method_copyArgumentType(method, i);
        same = type && strcmp(type, arguments[i].UTF8String) == 0;
        free(type);
        if (!same) return NO;
    }
    return YES;
}

int main(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_LAZY);
        Class cls = NSClassFromString(@"BKSProcessAssertion");
        SEL allocSEL = NSSelectorFromString(@"alloc");
        SEL initSEL = NSSelectorFromString(@"initWithPID:flags:reason:name:withHandler:");
        SEL validSEL = NSSelectorFromString(@"valid");
        SEL invalidateSEL = NSSelectorFromString(@"invalidate");
        Method allocMethod = class_getClassMethod(cls, allocSEL);
        Method initMethod = class_getInstanceMethod(cls, initSEL);
        Method validMethod = class_getInstanceMethod(cls, validSEL);
        Method invalidateMethod = class_getInstanceMethod(cls, invalidateSEL);
        if (!matches(allocMethod, "@", @[@"@", @":"]) ||
            !matches(initMethod, "@", @[@"@", @":", @"i", @"I", @"I", @"@", @"@?"]) ||
            !matches(validMethod, "B", @[@"@", @":"]) ||
            !matches(invalidateMethod, "v", @[@"@", @":"])) {
            fprintf(stderr, "失败：运行时签名不匹配\n");
            return 1;
        }
        // 原始错误类型必须被拒绝，不能调用后再尝试捕获崩溃。
        if (matches(initMethod, "@", @[@"@", @":", @"i", @"Q", @"Q", @"*", @"@?"]) ||
            matches(validMethod, "@", @[@"@", @":"]) ||
            matches(NULL, "v", @[])) {
            fprintf(stderr, "失败：签名校验未拒绝错误类型\n");
            return 2;
        }
        Allocate allocate = (Allocate)method_getImplementation(allocMethod);
        Initialize initialize = (Initialize)method_getImplementation(initMethod);
        IsValid valid = (IsValid)method_getImplementation(validMethod);
        Invalidate invalidate = (Invalidate)method_getImplementation(invalidateMethod);
        unsigned int granted = 0;
        for (unsigned int i = 0; i < 100; ++i) {
            @autoreleasepool {
                void *allocated = allocate((__bridge const void *)cls, allocSEL);
                if (!allocated) return 3;
                NSString *name = [NSString stringWithFormat:@"wiki.qaq.apelin.keepalive.%u", i];
                void *initialized = initialize(allocated, initSEL, getpid(), 1, 10005,
                                               (__bridge const void *)name, NULL);
                if (!initialized) return 4;
                id object = (__bridge_transfer id)initialized;
                if (valid((__bridge const void *)object, validSEL)) ++granted;
                invalidate((__bridge const void *)object, invalidateSEL);
                if (valid((__bridge const void *)object, validSEL)) return 5;
                // 重复 invalidate 必须安全，随后由 ARC 释放对象。
                invalidate((__bridge const void *)object, invalidateSEL);
            }
        }
        printf("通过：签名核验及错误类型拒绝，100 次创建、BOOL 读取、释放；授予 %u 次\n", granted);
    }
    return 0;
}
