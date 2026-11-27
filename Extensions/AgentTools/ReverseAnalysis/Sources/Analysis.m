#import "Runtime.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <math.h>
#include <poll.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

volatile sig_atomic_t RAStopping = 0;
double RANow(void) {
    static mach_timebase_info_data_t base;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&base); });
    return (double)mach_continuous_time() * base.numer / base.denom / 1e9;
}
void RAFail(NSString *code, NSString *message) {
    @throw [NSException exceptionWithName:[@"RA." stringByAppendingString:code] reason:message userInfo:nil];
}
BOOL RAInteger(id value, long long minimum, long long maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= minimum && number <= maximum && floor(number) == number;
}
BOOL RAIdentifier(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > 128) return NO;
    const unsigned char *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) if (bytes[i] <= 32 || bytes[i] >= 127) return NO;
    return YES;
}
static NSString *hexDigest(CC_SHA256_CTX *state) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, state);
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}
NSString *RAHashFile(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) RAFail(@"toolFailed", @"无法读取原生分析组件");
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    char bytes[65536]; ssize_t count;
    while ((count = read(fd, bytes, sizeof(bytes))) != 0) {
        if (count < 0) { if (errno == EINTR) continue; close(fd); RAFail(@"toolFailed", @"无法计算分析组件摘要"); }
        CC_SHA256_Update(&state, bytes, (CC_LONG)count);
    }
    close(fd); return hexDigest(&state);
}
static void prepareEngine(NSString *path) {
    // roothide 首次执行会更新 Mach-O 引导标记和相应签名页摘要。
    // 在接受任何任务、创建缓存键之前完成它，不忽略摘要中的任何字节。
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions)) RAFail(@"toolFailed", @"无法准备引擎启动检查");
    if (posix_spawnattr_init(&attributes)) { posix_spawn_file_actions_destroy(&actions); RAFail(@"toolFailed", @"无法准备引擎启动属性"); }
    int error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP);
    if (!error) error = posix_spawnattr_setpgroup(&attributes, 0);
    for (int fd = 0; fd < 3 && !error; fd++) error = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd ? O_WRONLY : O_RDONLY, 0);
    char *args[] = {(char *)path.fileSystemRepresentation, "--preflight", NULL};
    char *env[] = {"HOME=/dev/null", "LC_ALL=C", NULL};
    pid_t pid = -1;
    if (!error) error = posix_spawn(&pid, path.fileSystemRepresentation, &actions, &attributes, args, env);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    if (error) RAFail(@"toolFailed", @"引擎启动检查无法执行");
    double deadline = RANow() + 2;
    int status = 0;
    for (;;) {
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) break;
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || RAStopping || RANow() >= deadline) {
            kill(-pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            RAFail(@"toolFailed", @"引擎启动检查超时或被终止");
        }
        usleep(1000);
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) RAFail(@"toolFailed", @"引擎启动检查失败");
}
static NSString *dataDigest(NSString *directory) {
    NSString *index = [directory stringByAppendingPathComponent:@"data-sha256.json"];
    NSData *bytes = [NSData dataWithContentsOfFile:index];
    NSDictionary *entries = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL] : nil;
    if (![entries isKindOfClass:NSDictionary.class] || entries.count < 8 || entries.count > 64) RAFail(@"toolFailed", @"反编译语言数据清单无效");
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"];
    for (NSString *name in entries) {
        id expected = entries[name];
        if (![name isKindOfClass:NSString.class] || !name.length || [name isEqual:@"."] || [name isEqual:@".."] || [name rangeOfCharacterFromSet:safe.invertedSet].location != NSNotFound || ![expected isKindOfClass:NSString.class]) RAFail(@"toolFailed", @"反编译语言数据条目无效");
        NSString *path = [[directory stringByAppendingPathComponent:@"sleigh"] stringByAppendingPathComponent:name];
        if (![RAHashFile(path) isEqual:expected]) RAFail(@"toolFailed", @"反编译语言数据与构建摘要不符");
    }
    return RAHashFile(index);
}
@implementation RACall
- (void)check {
    if (self.cancelled || RAStopping) RAFail(@"cancelled", @"分析已取消，已回收工作进程");
    if (RANow() >= self.deadline) RAFail(@"timeout", @"分析超时，已回收工作进程");
}
@end

@interface RAWorker : NSObject
@property(nonatomic) pid_t pid;
@property(nonatomic) int input;
@property(nonatomic) int output;
@property(nonatomic) int diagnostic;
@property(nonatomic) NSUInteger diagnosticBytes;
@property(nonatomic) NSUInteger requests;
@property(nonatomic) double lastUsed;
@property(nonatomic, copy) NSString *key;
- (void)close;
- (id)receive:(RACall *)call;
- (id)query:(NSString *)command call:(RACall *)call;
@end
@implementation RAWorker
- (instancetype)init {
    if ((self = [super init])) { _input = _output = _diagnostic = -1; _pid = -1; }
    return self;
}
- (void)close {
    if (_pid > 0) {
        kill(-_pid, SIGKILL);
        while (waitpid(_pid, NULL, 0) < 0 && errno == EINTR) {}
        _pid = -1;
    }
    if (_input >= 0) close(_input);
    if (_output >= 0) close(_output);
    if (_diagnostic >= 0) close(_diagnostic);
    _input = _output = _diagnostic = -1;
}
- (void)dealloc { [self close]; }
- (NSData *)readExact:(NSUInteger)length call:(RACall *)call {
    NSMutableData *data = [NSMutableData dataWithLength:length]; NSUInteger offset = 0;
    while (offset < length) {
        [call check];
        struct pollfd items[2] = {{_output, POLLIN, 0}, {_diagnostic, POLLIN, 0}};
        int ready = poll(items, 2, 20);
        if (ready < 0) { if (errno == EINTR) continue; RAFail(@"toolFailed", @"无法读取分析进程"); }
        if (items[1].revents) {
            char bytes[8192]; ssize_t count = read(_diagnostic, bytes, sizeof(bytes));
            if (count > 0) {
                _diagnosticBytes += count;
                if (_diagnosticBytes > RAMaxFrame) RAFail(@"resultTooLarge", @"分析诊断超出限额，已回收工作进程");
                /* stderr 为有界诊断；阻塞宿主不能拖住取消路径。 */
                (void)write(STDERR_FILENO, bytes, (size_t)count);
            } else if (count == 0) { close(_diagnostic); _diagnostic = -1; }
        }
        if (items[0].revents) {
            ssize_t count = read(_output, (char *)data.mutableBytes + offset, length - offset);
            if (count == 0) RAFail(@"toolFailed", @"分析进程意外结束");
            if (count < 0) { if (errno == EINTR || errno == EAGAIN) continue; RAFail(@"toolFailed", @"分析进程读取失败"); }
            offset += count;
        }
    }
    return data;
}
- (id)receive:(RACall *)call {
    NSData *header = [self readExact:4 call:call]; const unsigned char *bytes = header.bytes;
    uint32_t length = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
    if (!length || length > RAMaxFrame) RAFail(@"resultTooLarge", @"分析响应超出限额");
    id value = [NSJSONSerialization JSONObjectWithData:[self readExact:length call:call] options:NSJSONReadingFragmentsAllowed error:NULL];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"ok"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value[@"ok"]) != CFBooleanGetTypeID()) RAFail(@"toolFailed", @"分析进程返回无效协议");
    if (![value[@"ok"] boolValue]) {
        NSString *code = value[@"error"];
        if ([code isEqual:@"output_limit"]) RAFail(@"resultTooLarge", @"分析结果超出限额");
        if ([code isEqual:@"function_not_found"]) RAFail(@"invalidArguments", @"未发现该地址对应的函数入口");
        RAFail(@"toolFailed", @"原生引擎未能完成分析");
    }
    if (!value[@"data"]) RAFail(@"toolFailed", @"分析响应缺少数据");
    return value[@"data"];
}
- (id)query:(NSString *)command call:(RACall *)call {
    [call check]; NSData *data = [[command stringByAppendingString:@"\n"] dataUsingEncoding:NSASCIIStringEncoding];
    ssize_t count;
    do { count = write(_input, data.bytes, data.length); } while (count < 0 && errno == EINTR);
    if (count != (ssize_t)data.length) RAFail(@"toolFailed", @"分析进程已退出");
    id value = [self receive:call]; _requests++; _lastUsed = RANow(); return value;
}
@end

/* 快照不留下名称；工作进程只得到 fd 4，不能写回输入。 */
static BOOL sameFile(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}
static uint32_t little32(const unsigned char *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}
static void validateMachO(NSData *bytes, off_t size, NSString *arch) {
    const unsigned char *p = bytes.bytes;
    if (bytes.length < 32 || little32(p) != 0xfeedfacf || little32(p + 4) != 0x100000c) RAFail(@"invalidArguments", @"只支持未加密的 ARM64 薄 Mach-O");
    uint32_t subtype = little32(p + 8) & 0xffffff;
    if (!((subtype == 0 && [arch isEqual:@"arm64"]) || (subtype == 2 && [arch isEqual:@"arm64e"]))) RAFail(@"invalidArguments", @"请求架构与样本不匹配");
    uint32_t count = little32(p + 16), commandBytes = little32(p + 20);
    if (commandBytes > size - 32 || count > commandBytes / 8 || bytes.length < 32 + (uint64_t)commandBytes) RAFail(@"invalidArguments", @"Mach-O 命令区越界");
    size_t offset = 32;
    for (uint32_t i = 0; i < count; i++) {
        if (offset + 8 > 32 + commandBytes) RAFail(@"invalidArguments", @"Mach-O 命令不完整");
        uint32_t cmd = little32(p + offset), length = little32(p + offset + 4);
        if (length < 8 || length % 8 || length > 32 + commandBytes - offset) RAFail(@"invalidArguments", @"Mach-O 命令长度非法");
        if ((cmd == 0x21 || cmd == 0x2c) && (length < (cmd == 0x2c ? 24 : 20) || little32(p + offset + 16))) RAFail(@"invalidArguments", @"不接受加密 Mach-O");
        offset += length;
    }
    if (offset != 32 + commandBytes) RAFail(@"invalidArguments", @"Mach-O 命令计数不符");
}
static int snapshot(RACall *call, int provided, NSString **digest) {
    int source = -1, destination = -1; char *temporaryName = NULL;
    @try {
        if (provided >= 0) source = fcntl(provided, F_DUPFD_CLOEXEC, 10);
        else {
            NSString *path = call.arguments[@"binary"];
            if (![path hasPrefix:@"/"] || [path rangeOfString:@"\0"].location != NSNotFound) RAFail(@"invalidArguments", @"binary 必须是绝对路径，或由宿主传入只读附件");
            char resolved[PATH_MAX];
            if (!realpath(path.fileSystemRepresentation, resolved)) RAFail(@"invalidArguments", @"无法规范化输入路径");
            source = open(resolved, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            char actual[PATH_MAX];
            if (source < 0 || fcntl(source, F_GETPATH, actual) < 0 || strcmp(actual, resolved)) RAFail(@"invalidArguments", @"输入路径在打开期间发生变化");
        }
        struct stat before, after;
        if (source < 0 || fstat(source, &before) || !S_ISREG(before.st_mode)) RAFail(@"invalidArguments", @"只接受普通二进制文件");
        if (before.st_size < 32 || before.st_size > RAMaxFile) RAFail(@"invalidArguments", @"输入文件必须为 32 字节至 48 MiB");
        NSString *folder = NSProcessInfo.processInfo.environment[@"TMPDIR"] ?: NSTemporaryDirectory();
        temporaryName = strdup([[folder stringByAppendingPathComponent:@"xyzl-reverse.XXXXXX"] fileSystemRepresentation]);
        if (!temporaryName) RAFail(@"toolFailed", @"无法分配快照名称");
        destination = mkstemp(temporaryName);
        if (destination < 0) RAFail(@"toolFailed", @"无法创建私有分析快照");
        fcntl(destination, F_SETFD, FD_CLOEXEC);
        CC_SHA256_CTX state; CC_SHA256_Init(&state);
        NSMutableData *all = [NSMutableData dataWithCapacity:(NSUInteger)before.st_size];
        char bytes[65536]; off_t offset = 0;
        while (offset < before.st_size) {
            [call check]; ssize_t count = pread(source, bytes, MIN(sizeof(bytes), (size_t)(before.st_size - offset)), offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) RAFail(@"toolFailed", @"读取期间样本发生变化");
            [all appendBytes:bytes length:count]; CC_SHA256_Update(&state, bytes, (CC_LONG)count);
            ssize_t written = 0;
            while (written < count) {
                ssize_t n = write(destination, bytes + written, count - written);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) RAFail(@"toolFailed", @"写入分析快照失败");
                written += n;
            }
            offset += count;
        }
        if (fstat(source, &after) || !sameFile(before, after)) RAFail(@"toolFailed", @"读取期间样本发生变化，请重试");
        validateMachO(all, before.st_size, call.arguments[@"arch"]);
        *digest = hexDigest(&state);
        if (fchmod(destination, 0400) != 0) RAFail(@"toolFailed", @"无法限制快照权限");
        int result = open(temporaryName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat written, reopened;
        if (result < 0 || fstat(destination, &written) || fstat(result, &reopened) || !sameFile(written, reopened)) {
            if (result >= 0) close(result);
            RAFail(@"toolFailed", @"无法获取只读快照");
        }
        if (unlink(temporaryName) != 0) { close(result); RAFail(@"toolFailed", @"无法匿名化快照"); }
        free(temporaryName); temporaryName = NULL;
        return result;
    } @finally {
        if (source >= 0) close(source);
        if (destination >= 0) close(destination);
        if (temporaryName) { if (destination >= 0) unlink(temporaryName); free(temporaryName); }
    }
}

static id convertAddresses(id value) {
    if ([value isKindOfClass:NSArray.class]) { NSMutableArray *out = [NSMutableArray array]; for (id item in value) [out addObject:convertAddresses(item)]; return out; }
    if (![value isKindOfClass:NSDictionary.class]) return value;
    NSSet *keys = [NSSet setWithArray:@[@"addr", @"offset", @"jump", @"fail", @"ptr", @"from", @"to", @"ref", @"fcn_addr"]];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in value) {
        id item = value[key];
        if ([keys containsObject:key] && [item isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)item) != CFBooleanGetTypeID()) out[key] = [NSString stringWithFormat:@"0x%llx", [item unsignedLongLongValue]];
        else out[key] = convertAddresses(item);
    }
    return out;
}
@implementation RAAnalysis {
    NSString *_directory, *_engineHash, *_dataHash;
    NSMutableArray<RAWorker *> *_sessions;
    double _idle;
}
- (instancetype)initWithDirectory:(NSString *)directory idleSeconds:(double)idle {
    if ((self = [super init])) {
        _directory = directory; _idle = idle; _sessions = [NSMutableArray array];
        prepareEngine([directory stringByAppendingPathComponent:@"xyzl-reverse-worker"]);
        _engineHash = RAHashFile([directory stringByAppendingPathComponent:@"xyzl-reverse-worker"]);
        _dataHash = dataDigest(directory);
    }
    return self;
}
- (void)expire {
    for (RAWorker *worker in [_sessions copy]) {
        /* 不 waitpid(WNOHANG)：避免已回收 PID 在 close 时误伤另一个进程组。 */
        siginfo_t info = {0};
        BOOL exited = waitid(P_PID, (id_t)worker.pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == worker.pid;
        if (exited || RANow() - worker.lastUsed >= _idle || worker.requests >= 128 || (kill(worker.pid, 0) < 0 && errno == ESRCH)) {
            [worker close]; [_sessions removeObject:worker];
        }
    }
}
- (RAWorker *)start:(int)fd key:(NSString *)key call:(RACall *)call {
    if (![RAHashFile([_directory stringByAppendingPathComponent:@"xyzl-reverse-worker"]) isEqual:_engineHash]) RAFail(@"toolFailed", @"分析引擎已变化，请重新打开扩展");
    if (![dataDigest(_directory) isEqual:_dataHash]) RAFail(@"toolFailed", @"语言数据清单已变化，请重新打开扩展");
    RAWorker *worker = [RAWorker new]; worker.key = key;
    int pipes[3][2] = {{-1, -1}, {-1, -1}, {-1, -1}};
    posix_spawn_file_actions_t actions; posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr);
    @try {
        for (int i = 0; i < 3; i++) {
            if (pipe(pipes[i])) RAFail(@"toolFailed", @"无法创建分析管道");
            /* 先移到高位，避免任何来源与子进程的 0、1、2、4 冲突。 */
            for (int j = 0; j < 2; j++) {
                int old = pipes[i][j]; pipes[i][j] = fcntl(old, F_DUPFD_CLOEXEC, 10); close(old);
                if (pipes[i][j] < 0) RAFail(@"toolFailed", @"无法保留分析描述符");
            }
        }
        posix_spawn_file_actions_adddup2(&actions, pipes[0][0], 0);
        posix_spawn_file_actions_adddup2(&actions, pipes[1][1], 1);
        posix_spawn_file_actions_adddup2(&actions, pipes[2][1], 2);
        int copy = fcntl(fd, F_DUPFD_CLOEXEC, 10);
        if (copy < 0) RAFail(@"toolFailed", @"无法传递分析快照");
        posix_spawn_file_actions_adddup2(&actions, copy, 4);
        short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
        posix_spawnattr_setflags(&attr, flags); posix_spawnattr_setpgroup(&attr, 0);
        sigset_t defaults, mask; sigemptyset(&mask); sigfillset(&defaults);
        posix_spawnattr_setsigdefault(&attr, &defaults); posix_spawnattr_setsigmask(&attr, &mask);
        NSString *path = [_directory stringByAppendingPathComponent:@"xyzl-reverse-worker"];
        NSString *sleigh = [@"SLEIGHHOME=" stringByAppendingString:[_directory stringByAppendingPathComponent:@"sleigh"]];
        NSString *parent = [NSString stringWithFormat:@"RA_PARENT_PID=%d", getpid()];
        char *argv[] = {(char *)path.fileSystemRepresentation, "/dev/fd/4", NULL};
        char *env[] = {"R2_NOPLUGINS=1", "R2_RCFILE=/dev/null", "HOME=/dev/null", "LC_ALL=C", (char *)sleigh.UTF8String, (char *)parent.UTF8String, NULL};
        pid_t pid = -1; int error = posix_spawn(&pid, path.fileSystemRepresentation, &actions, &attr, argv, env); close(copy);
        if (error) RAFail(@"toolFailed", @"无法启动原生分析进程");
        worker.pid = pid;
        fprintf(stderr, "逆向工作进程 pid=%d\n", pid); fflush(stderr);
        worker.input = pipes[0][1]; pipes[0][1] = -1;
        worker.output = pipes[1][0]; pipes[1][0] = -1;
        worker.diagnostic = pipes[2][0]; pipes[2][0] = -1;
        fcntl(worker.output, F_SETFL, O_NONBLOCK); fcntl(worker.diagnostic, F_SETFL, O_NONBLOCK);
        NSDictionary *ready = [worker receive:call];
        if (![ready isKindOfClass:NSDictionary.class] || ![ready isEqual:@{@"ready": @YES, @"analysis_runs": @1}]) RAFail(@"toolFailed", @"分析进程初始化协议错误");
        worker.lastUsed = RANow(); return worker;
    } @catch (NSException *error) { [worker close]; @throw; }
    @finally {
        posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr);
        for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++) if (pipes[i][j] >= 0) close(pipes[i][j]);
    }
}
- (NSDictionary *)run:(RACall *)call descriptor:(int)descriptor {
    [call check]; [self expire]; double started = RANow();
    NSString *digest = nil; int fd = snapshot(call, descriptor, &digest);
    RAWorker *worker = nil;
    @try {
        NSString *key = [@[digest, call.arguments[@"arch"], _engineHash, _dataHash, @"1"] componentsJoinedByString:@":"];
        for (RAWorker *candidate in _sessions) if ([candidate.key isEqual:key]) { worker = candidate; break; }
        BOOL hit = worker != nil;
        if (!worker) {
            while (_sessions.count >= 2) { [_sessions.firstObject close]; [_sessions removeObjectAtIndex:0]; }
            worker = [self start:fd key:key call:call];
        } else [_sessions removeObject:worker];
        [_sessions addObject:worker];
        NSString *name = call.tool, *command;
        if ([name isEqual:@"analyze_functions"]) command = @"functions";
        else {
            NSString *op = [name isEqual:@"analyze_cfg"] ? @"cfg" : [name isEqual:@"decompile_function"] ? @"decompile" : [@"refs_" stringByAppendingString:call.arguments[@"direction"]];
            command = [NSString stringWithFormat:@"%@ %@", op, call.arguments[@"address"]];
        }
        id raw = [worker query:command call:call], data;
        if ([name isEqual:@"analyze_functions"]) {
            if (![raw isKindOfClass:NSArray.class]) RAFail(@"toolFailed", @"函数列表格式错误");
            NSArray *items = [raw sortedArrayUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"addr"] compare:b[@"addr"]]; }];
            NSUInteger offset = [call.arguments[@"offset"] unsignedIntegerValue], limit = call.arguments[@"limit"] ? [call.arguments[@"limit"] unsignedIntegerValue] : 100;
            NSMutableArray *page = [NSMutableArray array];
            for (NSUInteger i = MIN(offset, items.count); i < items.count && page.count < limit; i++) {
                NSDictionary *item = items[i];
                if (!item[@"addr"] || !item[@"name"] || !item[@"size"] || !item[@"nbbs"]) RAFail(@"toolFailed", @"函数条目缺少字段");
                [page addObject:@{@"address": [NSString stringWithFormat:@"0x%llx", [item[@"addr"] unsignedLongLongValue]], @"name": item[@"name"], @"size": item[@"size"], @"blocks": item[@"nbbs"]}];
            }
            data = @{@"functions": page, @"total": @(items.count), @"next_offset": offset < items.count && offset + page.count < items.count ? @(offset + page.count) : NSNull.null};
        } else {
            if ([name isEqual:@"decompile_function"]) {
                if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"code"] isKindOfClass:NSString.class] || ![raw[@"code"] length]) RAFail(@"toolFailed", @"未产生有效的 C 伪代码");
            } else if (![raw isKindOfClass:NSArray.class]) RAFail(@"toolFailed", @"分析结果格式错误");
            data = convertAddresses(raw);
        }
        NSDictionary *result = @{@"data": data, @"meta": @{@"cache_hit": @(hit), @"pid": @(worker.pid), @"analysis_runs": @1, @"sha256": digest, @"arch": call.arguments[@"arch"], @"engine_sha256": _engineHash, @"data_sha256": _dataHash, @"elapsed_ms": @((RANow() - started) * 1000)}};
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if (!encoded || encoded.length > RAMaxReply) RAFail(@"resultTooLarge", @"结果超出 256 KiB；不会返回截断的伪代码");
        [call check]; return result;
    } @catch (NSException *error) { [worker close]; if (worker) [_sessions removeObject:worker]; @throw; }
    @finally { close(fd); }
}
- (void)close { for (RAWorker *worker in _sessions) [worker close]; [_sessions removeAllObjects]; }
@end
