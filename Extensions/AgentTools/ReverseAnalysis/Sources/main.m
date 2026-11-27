#import "Runtime.h"
#include <mach-o/dyld.h>
#include <math.h>
#include <unistd.h>
#include "Descriptors.inc"

int main(int argc, char **argv) {
    @autoreleasepool {
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:RADescriptors length:sizeof(RADescriptors)] options:0 error:NULL];
        if (!manifest) return 78;
        if (argc == 2 && !strcmp(argv[1], "--describe")) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:NULL];
            [NSFileHandle.fileHandleWithStandardOutput writeData:data];
            [NSFileHandle.fileHandleWithStandardOutput writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            return 0;
        }
        double idle = 60;
        if (argc == 3 && !strcmp(argv[1], "--idle-seconds")) {
            char *end = NULL; idle = strtod(argv[2], &end);
            if (!*argv[2] || *end || !isfinite(idle) || idle < 1 || idle > 60) return 64;
        } else if (argc != 1) return 64;
        char executable[PATH_MAX], resolved[PATH_MAX]; uint32_t length = sizeof(executable);
        if (_NSGetExecutablePath(executable, &length) || !realpath(executable, resolved)) return 78;
        NSString *directory = [[NSString stringWithUTF8String:resolved] stringByDeletingLastPathComponent];
        @try { return RAServe(manifest, directory, idle); }
        @catch (NSException *error) { fputs("原生逆向扩展初始化失败\n", stderr); return 70; }
    }
}
