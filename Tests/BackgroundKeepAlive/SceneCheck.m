#define APELIN_FOREGROUND_TEST 1
#include "../../Background/ApelinForeground.m"
#include <unistd.h>

// 使用可控对象执行生产 hook；不会向真实 SpringBoard 注入或修改其状态。
@interface APFTestSettings : NSObject
@property BOOL foreground;
@property BOOL backgrounded;
@property unsigned long long deactivationReasons;
@property NSInteger geometry;
@end
@implementation APFTestSettings
- (id)copyWithZone:(NSZone *)zone {
    APFTestSettings *copy = [[[self class] allocWithZone:zone] init];
    copy.foreground = self.foreground;
    copy.backgrounded = self.backgrounded;
    copy.deactivationReasons = self.deactivationReasons;
    copy.geometry = self.geometry;
    return copy;
}
- (id)mutableCopyWithZone:(NSZone *)zone { return [self copyWithZone:zone]; }
@end

@interface APFTestProcess : NSObject
@property (copy) NSString *bundleIdentifier;
@end
@implementation APFTestProcess @end
@interface APFTestScene : NSObject
@property (strong) APFTestProcess *clientProcess;
@end
@implementation APFTestScene @end
@interface APFTestProcessState : NSObject
- (int)pid;
@end
@implementation APFTestProcessState
- (int)pid { return getpid(); }
@end
@interface APFTestApplication : NSObject
- (id)processState;
@end
@implementation APFTestApplication
- (id)processState { return [APFTestProcessState new]; }
@end
@interface SBApplicationController : NSObject
+ (id)sharedInstance;
- (id)applicationWithBundleIdentifier:(id)bundle;
@end
@implementation SBApplicationController
+ (id)sharedInstance { static id instance; if (!instance) instance = [self new]; return instance; }
- (id)applicationWithBundleIdentifier:(id)bundle { return [bundle isEqual:APFBundle] ? [APFTestApplication new] : nil; }
@end

static id APFSeenSettings, APFSeenTransition, APFSeenCompletion;
static unsigned APFCalls, APFNotices, APFNotificationChanges, APFLastNotificationState;
static void APFTestOriginal(id self, SEL cmd, id settings, id transition, id completion) {
    (void)self; (void)cmd;
    APFCalls++;
    APFSeenSettings = settings;
    APFSeenTransition = transition;
    APFSeenCompletion = completion;
}
static void APFTestNoticeOriginal(id self, SEL cmd, id notice, id bundle, id completion) {
    (void)self; (void)cmd; (void)notice; (void)bundle;
    APFNotices++;
    APFSeenCompletion = completion;
}
@interface APFTestServer : NSObject
- (void)_didChangeApplicationState:(unsigned)state forBundleIdentifier:(id)bundle;
@end
@implementation APFTestServer
- (void)_didChangeApplicationState:(unsigned)state forBundleIdentifier:(id)bundle {
    NSCAssert([bundle isEqual:APFBundle], @"不能改变其他应用通知状态");
    APFNotificationChanges++;
    APFLastNotificationState = state;
}
@end

int main(void) {
    @autoreleasepool {
        APFReady = YES;
        APFScenes = [NSMapTable weakToStrongObjectsMapTable];
        APFOriginalScene = APFTestOriginal;
        APFOriginalNotice = APFTestNoticeOriginal;
        uint64_t pid = (uint64_t)(uint32_t)getpid() << 32;
        atomic_store(&APFRequest, pid | 3);
        APFTestSettings *settings = [APFTestSettings new];
        settings.backgrounded = YES;
        settings.deactivationReasons = 17;
        settings.geometry = 123;
        APFTestScene *scene = [APFTestScene new];
        scene.clientProcess = [APFTestProcess new];
        scene.clientProcess.bundleIdentifier = APFBundle;
        SEL update = sel_registerName("updateSettings:withTransitionContext:completion:");
        id transition = [NSObject new];
        id completion = [NSObject new];
        APFSceneUpdate(scene, update, settings, transition, completion);
        NSCAssert(APFSeenSettings == settings, @"首次配置必须原样转交");
        APFSceneUpdate(scene, update, settings, transition, completion);
        APFTestSettings *replacement = APFSeenSettings;
        NSCAssert(replacement != settings && replacement.foreground && !replacement.backgrounded &&
                  replacement.deactivationReasons == 0 && replacement.geometry == 123, @"必须只修改场景副本的激活字段");
        NSCAssert(settings.backgrounded && settings.deactivationReasons == 17, @"不能篡改系统输入");
        NSCAssert(APFCalls == 2 && APFSeenTransition == transition && APFSeenCompletion == completion, @"必须转交原 transition 和 completion");
        scene.clientProcess.bundleIdentifier = @"com.example.other";
        APFSceneUpdate(scene, update, settings, transition, completion);
        NSCAssert(APFSeenSettings == settings && APFCalls == 3, @"其他应用必须原样转交");
        scene.clientProcess.bundleIdentifier = APFBundle;
        atomic_store(&APFRequest, pid | 2);
        APFRestoreScenes();
        replacement = APFSeenSettings;
        NSCAssert(!replacement.foreground && replacement.backgrounded && replacement.deactivationReasons == 17, @"关闭必须恢复最后系统状态");
        NSCAssert(!atomic_load(&APFApplied), @"关闭后不能声称仍在保活");
        atomic_store(&APFRequest, ((uint64_t)(getpid() + 1) << 32) | 3);
        NSCAssert(!APFHolding(), @"陈旧 PID 不能继续保活");
        atomic_store(&APFRequest, pid | 3);
        APFTestServer *server = [APFTestServer new];
        APFNotice(server, NULL, nil, APFBundle, completion);
        NSCAssert(APFNotices == 1 && APFNotificationChanges == 1 && APFLastNotificationState == 4 && APFSeenCompletion == completion, @"前台通知必须调整状态且保留完成回调");
        APFNotice(server, NULL, nil, @"com.example.other", completion);
        NSCAssert(APFNotificationChanges == 1 && APFNotices == 2, @"其他应用通知不改动");
        atomic_store(&APFRequest, pid | 1);
        APFNotice(server, NULL, nil, APFBundle, completion);
        NSCAssert(APFNotificationChanges == 1 && APFNotices == 3, @"关闭通知开关后不再强制递送");
        NSCAssert(APFForegroundSettings([NSObject new]) == nil, @"不兼容设置对象必须安全降级");
        NSCAssert(!APFSignature([APFTestServer class], sel_registerName("_didChangeApplicationState:forBundleIdentifier:"), "v", @[@"Q", @"@"]), @"必须拒绝整数 ABI 不匹配");
        puts("通过：场景副本、其他应用隔离、transition/completion、关闭恢复、陈旧 PID、通知开关及 ABI 拒绝；不代表真机保活生效");
    }
    return 0;
}
