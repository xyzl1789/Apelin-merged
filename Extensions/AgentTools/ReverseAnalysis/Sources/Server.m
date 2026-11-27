#import "Runtime.h"
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

@interface RAAttachments : NSObject
@property(nonatomic) int socket;
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic, strong) NSMutableDictionary *pending;
- (void)receive;
- (int)take:(NSDictionary *)reference call:(RACall *)call;
- (void)discard:(NSArray *)references;
- (void)expire;
- (void)close;
@end
@implementation RAAttachments
- (instancetype)init {
    if ((self = [super init])) {
        _socket = -1; _condition = [NSCondition new]; _pending = [NSMutableDictionary dictionary];
        NSString *text = NSProcessInfo.processInfo.environment[@"APELIN_TOOL_ATTACHMENT_FD"];
        if (text.length && [text isEqual:[NSString stringWithFormat:@"%d", text.intValue]] && text.intValue > 2) {
            int fd = text.intValue, type = 0; socklen_t size = sizeof(type); struct stat info;
            if (!fstat(fd, &info) && S_ISSOCK(info.st_mode) && !getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &size) && type == SOCK_DGRAM) {
                _socket = fd; fcntl(fd, F_SETFD, FD_CLOEXEC); fcntl(fd, F_SETFL, O_NONBLOCK);
            }
        }
    }
    return self;
}
- (void)expire {
    [_condition lock];
    for (NSString *key in [_pending.allKeys copy]) {
        NSDictionary *entry = _pending[key];
        if (RANow() - [entry[@"time"] doubleValue] >= 60) { close([entry[@"fd"] intValue]); [_pending removeObjectForKey:key]; }
    }
    [_condition unlock];
}
- (void)receive {
    if (_socket < 0) return;
    for (int iteration = 0; iteration < 32; iteration++) {
        char payload[129]; union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int) * 64)]; } control;
        struct iovec vector = {payload, sizeof(payload)};
        struct msghdr message = {0}; message.msg_iov = &vector; message.msg_iovlen = 1;
        message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
        ssize_t count = recvmsg(_socket, &message, 0);
        if (count < 0) { if (errno == EINTR) continue; return; }
        int descriptors[64]; int number = 0; BOOL valid = !(message.msg_flags & (MSG_CTRUNC | MSG_TRUNC));
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
            if (header->cmsg_len < CMSG_LEN(0)) { valid = NO; continue; }
            if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) { valid = NO; continue; }
            size_t length = header->cmsg_len - CMSG_LEN(0);
            if (length % sizeof(int)) valid = NO;
            for (size_t i = 0; i < length / sizeof(int) && number < 64; i++) {
                int fd; memcpy(&fd, (char *)CMSG_DATA(header) + i * sizeof(int), sizeof(fd)); descriptors[number++] = fd;
                fcntl(fd, F_SETFD, FD_CLOEXEC);
            }
        }
        NSString *identifier = count > 0 && count <= 128 ? [[NSString alloc] initWithBytes:payload length:count encoding:NSASCIIStringEncoding] : nil;
        struct stat info;
        valid = valid && number == 1 && RAIdentifier(identifier) && !fstat(descriptors[0], &info) && S_ISREG(info.st_mode) && info.st_size >= 0 && info.st_size <= RAMaxFile;
        [_condition lock];
        if (valid && !_pending[identifier] && _pending.count < 32) {
            _pending[identifier] = @{@"fd": @(descriptors[0]), @"size": @(info.st_size), @"time": @(RANow())};
            [_condition broadcast];
        } else for (int i = 0; i < number; i++) close(descriptors[i]);
        [_condition unlock];
    }
}
- (int)take:(NSDictionary *)reference call:(RACall *)call {
    NSString *identifier = reference[@"id"]; double deadline = MIN(call.deadline, RANow() + 2);
    for (;;) {
        [call check]; [_condition lock]; NSDictionary *entry = _pending[identifier];
        if (entry) {
            [_pending removeObjectForKey:identifier]; [_condition unlock];
            int fd = [entry[@"fd"] intValue];
            if (reference[@"byteCount"] && (![reference[@"byteCount"] isEqual:entry[@"size"]])) { close(fd); RAFail(@"attachmentRejected", @"附件大小与声明不符"); }
            return fd;
        }
        if (_socket < 0 || RANow() >= deadline) { [_condition unlock]; RAFail(@"attachmentRejected", @"宿主未及时传入有效的文件描述符"); }
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; [_condition unlock];
    }
}
- (void)discard:(NSArray *)references {
    [_condition lock];
    for (id reference in references) {
        if (![reference isKindOfClass:NSDictionary.class] || !RAIdentifier(reference[@"id"])) continue;
        NSString *identifier = reference[@"id"]; NSDictionary *entry = _pending[identifier];
        if (entry) { close([entry[@"fd"] intValue]); [_pending removeObjectForKey:identifier]; }
    }
    [_condition unlock];
}
- (void)close {
    [_condition lock];
    for (NSDictionary *entry in _pending.allValues) close([entry[@"fd"] intValue]);
    [_pending removeAllObjects];
    if (_socket >= 0) close(_socket); _socket = -1; [_condition broadcast]; [_condition unlock];
}
@end

@interface RAServer : NSObject
@property(nonatomic, strong) NSDictionary *manifest;
@property(nonatomic, strong) NSDictionary *tools;
@property(nonatomic, strong) RAAttachments *attachments;
@property(nonatomic, strong) NSLock *state;
@property(nonatomic, strong) NSLock *writer;
@property(nonatomic, strong) RACall *active;
@property(nonatomic) int protocol;
@property(nonatomic) BOOL negotiated;
@property(nonatomic) NSUInteger outboundLimit;
@property(nonatomic, strong) RAAnalysis *analysis;
@property(nonatomic, strong) dispatch_queue_t queue;
- (void)handle:(NSData *)line;
- (void)send:(NSDictionary *)frame;
- (void)error:(NSString *)code message:(NSString *)message identifier:(NSString *)identifier;
@end
static void validateArguments(NSDictionary *args, NSString *tool) {
    if (![args isKindOfClass:NSDictionary.class]) RAFail(@"invalidArguments", @"args 必须是对象");
    NSMutableSet *allowed = [NSMutableSet setWithArray:@[@"binary", @"arch", @"timeout_seconds"]];
    BOOL functions = [tool isEqual:@"analyze_functions"];
    [allowed addObjectsFromArray:functions ? @[@"offset", @"limit"] : @[@"address"]];
    if ([tool isEqual:@"analyze_references"]) [allowed addObject:@"direction"];
    for (id key in args) if (![allowed containsObject:key]) RAFail(@"invalidArguments", @"不接受未知参数或任意引擎命令");
    if (![args[@"binary"] isKindOfClass:NSString.class] || ![args[@"binary"] length] || [args[@"binary"] rangeOfString:@"\0"].location != NSNotFound || ![@[@"arm64", @"arm64e"] containsObject:args[@"arch"] ?: NSNull.null]) RAFail(@"invalidArguments", @"必须提供 binary 和明确的 arm64/arm64e 架构");
    if (args[@"timeout_seconds"]) {
        id value = args[@"timeout_seconds"];
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() || !isfinite([value doubleValue]) || [value doubleValue] < 0.001 || [value doubleValue] > 60) RAFail(@"invalidArguments", @"timeout_seconds 必须在 0.001 至 60 秒之间");
    }
    if (functions) {
        if ((args[@"offset"] && !RAInteger(args[@"offset"], 0, INT32_MAX)) || (args[@"limit"] && !RAInteger(args[@"limit"], 1, 500))) RAFail(@"invalidArguments", @"函数分页必须使用非负 offset 和 1 至 500 的 limit");
    } else {
        NSString *address = args[@"address"];
        if (![address isKindOfClass:NSString.class] || ![address hasPrefix:@"0x"] || address.length < 3 || address.length > 18) RAFail(@"invalidArguments", @"地址必须是十六进制函数入口");
        for (NSUInteger i = 2; i < address.length; i++) {
            unichar c = [address characterAtIndex:i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) RAFail(@"invalidArguments", @"地址不接受表达式或命令");
        }
        if ([tool isEqual:@"analyze_references"] && ![@[@"in", @"out"] containsObject:args[@"direction"] ?: NSNull.null]) RAFail(@"invalidArguments", @"引用方向必须是 in 或 out");
    }
}
@implementation RAServer
- (void)send:(NSDictionary *)frame {
    NSMutableDictionary *value = [frame mutableCopy]; value[@"protocolVersion"] = @1;
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if (!encoded || encoded.length > _outboundLimit) {
        value = [@{@"protocolVersion": @1, @"type": @"error", @"error": @{@"code": @"resultTooLarge", @"message": @"响应超出协商帧限额"}} mutableCopy];
        if (frame[@"requestID"]) value[@"requestID"] = frame[@"requestID"];
        encoded = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
        if (!encoded || encoded.length > _outboundLimit) { RAStopping = 1; return; }
    }
    NSMutableData *data = [encoded mutableCopy]; [data appendBytes:"\n" length:1];
    [_writer lock]; NSUInteger offset = 0; double deadline = RANow() + 0.5;
    while (offset < data.length && !RAStopping && RANow() < deadline) {
        ssize_t count = write(_protocol, (char *)data.bytes + offset, data.length - offset);
        if (count > 0) offset += count;
        else if (count < 0 && (errno == EINTR || errno == EAGAIN)) { struct pollfd item = {_protocol, POLLOUT, 0}; poll(&item, 1, 10); }
        else break;
    }
    if (offset != data.length) RAStopping = 1;
    [_writer unlock];
}
- (void)error:(NSString *)code message:(NSString *)message identifier:(NSString *)identifier {
    NSMutableDictionary *frame = [@{@"type": @"error", @"error": @{@"code": code, @"message": message}} mutableCopy];
    if (identifier) frame[@"requestID"] = identifier;
    [self send:frame];
}
- (void)handle:(NSData *)line {
    id frame = [NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:NULL];
    NSString *identifier = [frame isKindOfClass:NSDictionary.class] && RAIdentifier(frame[@"requestID"]) ? frame[@"requestID"] : nil;
    if (![frame isKindOfClass:NSDictionary.class] || ![frame[@"type"] isKindOfClass:NSString.class] || !RAInteger(frame[@"protocolVersion"], 0, INT32_MAX)) { [self error:@"badFrame" message:@"无法解析协议帧" identifier:identifier]; return; }
    NSString *type = frame[@"type"];
    if ([type isEqual:@"hello"]) {
        if (!identifier) { [self error:@"badFrame" message:@"缺少有效的 requestID" identifier:nil]; return; }
        if (_negotiated) { [self error:@"badFrame" message:@"不能重复握手" identifier:identifier]; return; }
        id offered = frame[@"supportedVersions"] ?: @[frame[@"protocolVersion"]];
        BOOL shared = NO;
        if ([offered isKindOfClass:NSArray.class]) for (id value in offered) if (RAInteger(value, 1, 1)) shared = YES;
        if (!shared) { [self error:@"protocolVersionMismatch" message:@"没有共同协议版本" identifier:identifier]; return; }
        if (frame[@"maxFrameBytes"] && !RAInteger(frame[@"maxFrameBytes"], 1, INT32_MAX)) { [self error:@"badFrame" message:@"maxFrameBytes 无效" identifier:identifier]; return; }
        _negotiated = YES;
        if (frame[@"maxFrameBytes"]) _outboundLimit = MIN(RAMaxFrame, [frame[@"maxFrameBytes"] unsignedIntegerValue]);
        [self send:@{@"type": @"hello", @"requestID": identifier, @"supportedVersions": @[@1], @"peer": @{@"name": _manifest[@"id"], @"version": _manifest[@"version"]}, @"tools": [_manifest[@"tools"] valueForKey:@"name"], @"maxConcurrentCalls": @1, @"maxFrameBytes": @(RAMaxFrame)}];
        return;
    }
    if (!_negotiated) { [self error:@"notNegotiated" message:@"请先完成 hello 握手" identifier:identifier]; return; }
    if (![frame[@"protocolVersion"] isEqual:@1]) { [self error:@"protocolVersionMismatch" message:@"协议版本与握手不符" identifier:identifier]; return; }
    if (!identifier) { [self error:@"badFrame" message:@"缺少有效的 requestID" identifier:nil]; return; }
    if ([type isEqual:@"cancel"]) {
        [_state lock]; if ([_active.identifier isEqual:identifier]) _active.cancelled = YES; [_state unlock]; return;
    }
    if (![type isEqual:@"call"]) { [self error:@"badFrame" message:@"宿主只能发送 hello、call 或 cancel" identifier:identifier]; return; }
    NSArray *references = [frame[@"attachments"] isKindOfClass:NSArray.class] ? frame[@"attachments"] : @[];
    @try {
        NSString *name = frame[@"tool"];
        if (![name isKindOfClass:NSString.class] || !_tools[name]) RAFail(@"unknownTool", @"没有此分析工具");
        NSDictionary *args = frame[@"args"] ?: @{}; validateArguments(args, name);
        if ((frame[@"attachments"] && ![frame[@"attachments"] isKindOfClass:NSArray.class]) || references.count > 1) RAFail(@"attachmentRejected", @"只接受一个绑定 binary 的输入附件");
        for (id reference in references) {
            if (![reference isKindOfClass:NSDictionary.class] || !RAIdentifier(reference[@"id"]) || ![reference[@"argument"] isEqual:@"binary"] || (reference[@"byteCount"] && !RAInteger(reference[@"byteCount"], 0, RAMaxFile))) RAFail(@"attachmentRejected", @"附件引用或大小声明无效");
        }
        RACall *call = [RACall new]; call.identifier = identifier; call.tool = name; call.arguments = args; call.references = references;
        call.deadline = RANow() + (args[@"timeout_seconds"] ? [args[@"timeout_seconds"] doubleValue] : 15);
        [_state lock]; RACall *existing = _active;
        if (!existing) _active = call; [_state unlock];
        if (existing) RAFail([existing.identifier isEqual:identifier] ? @"duplicateRequest" : @"busy", @"本扩展每次只接受一个调用，其他调用应由宿主排队");
        dispatch_async(_queue, ^{ @autoreleasepool {
            int fd = -1; NSDictionary *response;
            @try {
                [call check];
                if (references.count) fd = [self.attachments take:references.firstObject call:call];
                NSDictionary *result = [self.analysis run:call descriptor:fd];
                NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                response = @{@"type": @"result", @"requestID": identifier, @"content": @[@{@"type": @"text", @"text": text}]};
                NSMutableDictionary *measured = [response mutableCopy]; measured[@"protocolVersion"] = @1;
                NSData *wire = [NSJSONSerialization dataWithJSONObject:measured options:NSJSONWritingSortedKeys error:NULL];
                if (!wire || wire.length > self.outboundLimit) {
                    [self.analysis close]; RAFail(@"resultTooLarge", @"结果超出协商帧限额，已回收缓存会话");
                }
            } @catch (NSException *error) {
                NSString *code = [error.name hasPrefix:@"RA."] ? [error.name substringFromIndex:3] : @"toolFailed";
                response = @{@"type": @"error", @"requestID": identifier, @"error": @{@"code": code, @"message": [error.name hasPrefix:@"RA."] ? error.reason : @"分析适配层内部错误"}};
            } @finally { if (fd >= 0) close(fd); [self.attachments discard:references]; }
            [self.state lock]; self.active = nil; [self.state unlock];
            [self send:response];
        }});
    } @catch (NSException *error) {
        [_attachments discard:references];
        [self error:[error.name hasPrefix:@"RA."] ? [error.name substringFromIndex:3] : @"toolFailed" message:error.reason ?: @"请求处理失败" identifier:identifier];
    }
}
@end
static void stopped(int signalNumber) { (void)signalNumber; RAStopping = 1; }
int RAServe(NSDictionary *manifest, NSString *directory, double idleSeconds) {
    signal(SIGPIPE, SIG_IGN); signal(SIGTERM, stopped); signal(SIGINT, stopped);
    RAServer *server = [RAServer new]; server.manifest = manifest; server.outboundLimit = RAMaxFrame;
    NSMutableDictionary *tools = [NSMutableDictionary dictionary];
    for (NSDictionary *tool in manifest[@"tools"]) tools[tool[@"name"]] = tool;
    server.tools = tools; server.state = [NSLock new]; server.writer = [NSLock new];
    server.attachments = [RAAttachments new]; server.queue = dispatch_queue_create("com.xyzl.reverse-analysis", DISPATCH_QUEUE_SERIAL);
    server.protocol = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 10);
    if (server.protocol < 0 || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 70;
    fcntl(server.protocol, F_SETFL, O_NONBLOCK);
    fcntl(STDERR_FILENO, F_SETFL, O_NONBLOCK);
    @try { server.analysis = [[RAAnalysis alloc] initWithDirectory:directory idleSeconds:idleSeconds]; }
    @catch (NSException *error) { [server error:@"toolFailed" message:error.reason identifier:nil]; [server.attachments close]; close(server.protocol); return 70; }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, server.queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), NSEC_PER_SEC / 4, NSEC_PER_MSEC * 20);
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { [server.analysis expire]; } }); dispatch_resume(timer);
    NSMutableData *buffer = [NSMutableData data]; BOOL oversized = NO, eof = NO;
    while (!RAStopping && !eof) { @autoreleasepool {
        struct pollfd items[2] = {{STDIN_FILENO, POLLIN, 0}, {server.attachments.socket, POLLIN, 0}};
        int ready = poll(items, 2, 100);
        if (ready < 0) { if (errno == EINTR) continue; break; }
        if (items[1].revents) [server.attachments receive];
        [server.attachments expire];
        if (!items[0].revents) continue;
        unsigned char bytes[8192]; ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count < 0) { if (errno == EINTR || errno == EAGAIN) continue; break; }
        if (count == 0) { eof = YES; break; }
        for (ssize_t i = 0; i < count && !RAStopping; i++) {
            if (bytes[i] == '\n') {
                if (oversized) [server error:@"frameTooLarge" message:@"输入帧超过 1 MiB" identifier:nil];
                else [server handle:buffer];
                [buffer setLength:0]; oversized = NO;
            } else if (!oversized) {
                if (buffer.length >= RAMaxFrame) { [buffer setLength:0]; oversized = YES; }
                else [buffer appendBytes:bytes + i length:1];
            }
        }
    }}
    if (eof && buffer.length && !oversized && !RAStopping) [server handle:buffer];
    /* EOF 即宿主释放扩展；无需等下一次请求才回收缓存。 */
    [server.state lock]; server.active.cancelled = YES; [server.state unlock];
    dispatch_source_cancel(timer);
    dispatch_sync(server.queue, ^{ [server.analysis close]; });
    [server.attachments close]; close(server.protocol); return 0;
}
