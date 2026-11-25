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

@interface APFTestProcess : NSObject <NSCopying>
@property (copy) NSString *bundleIdentifier;
@end
@implementation APFTestProcess
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
@end
@interface APFTestScene : NSObject
@property (strong) APFTestProcess *clientProcess;
@end
@implementation APFTestScene @end
static int APFTestPID;
@interface APFTestProcessState : NSObject
- (int)pid;
@end
@implementation APFTestProcessState
- (int)pid { return APFTestPID; }
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

static BOOL APFSeenKillable;
static unsigned APFKillCalls;
@interface APFTestLayout : NSObject
@property (strong) NSDictionary *itemsToLayoutAttributesMap;
@end
@implementation APFTestLayout @end
@interface APFTestContainer : NSObject
@property (strong) APFTestLayout *appLayout;
@end
@implementation APFTestContainer @end
@interface APFTestIcon : NSObject
@property (copy) NSString *applicationBundleID;
@end
@implementation APFTestIcon @end
@interface APFTestIconView : NSObject
@property (strong) APFTestIcon *icon;
@end
@implementation APFTestIconView @end
static void APFTestKillOriginal(id self, SEL cmd, BOOL value) {
    (void)self; (void)cmd; APFKillCalls++; APFSeenKillable = value;
}
static long long APFTestAccessoryOriginal(id self, SEL cmd, id icon) {
    (void)self; (void)cmd; (void)icon; return 77;
}
static long long APFTestViewAccessoryOriginal(id self, SEL cmd) {
    (void)self; (void)cmd; return 78;
}
static id APFTestNameOriginal(id self, SEL cmd) {
    (void)self; (void)cmd; return @"原始应用名称";
}

static void APFCheckProtection(uint64_t pid) {
    APFTestPID = getpid();
    APFLockReady = APFMarksReady = YES;
    APFContainers = [NSMapTable weakToStrongObjectsMapTable];
    APFOriginalKillable = APFTestKillOriginal;
    APFOriginalAccessory = APFTestAccessoryOriginal;
    APFOriginalViewAccessory = APFTestViewAccessoryOriginal;
    APFOriginalName = APFTestNameOriginal;
    APFOptions = 28;
    atomic_store(&APFRequest, pid | 28); // 保活关闭，锁定仍独立工作。
    APFTestProcess *item = [APFTestProcess new]; item.bundleIdentifier = APFBundle;
    APFTestProcess *other = [APFTestProcess new]; other.bundleIdentifier = @"com.example.other";
    APFTestContainer *container = [APFTestContainer new];
    container.appLayout = [APFTestLayout new];
    container.appLayout.itemsToLayoutAttributesMap = @{item: @1};
    APFKillable(container, NULL, YES);
    NSCAssert(!APFSeenKillable && APFKillCalls == 1, @"本应用卡片应不可划掉，且只调用一次原方法");
    APFOptions = 24;
    APFRefreshContainers();
    NSCAssert(APFSeenKillable, @"关闭锁定必须恢复原始 YES");
    APFOptions = 28;
    APFKillable(container, NULL, NO);
    APFOptions = 24;
    APFRefreshContainers();
    NSCAssert(!APFSeenKillable, @"系统原值为 NO 时不能擅自改成 YES");
    APFOptions = 28;
    container.appLayout.itemsToLayoutAttributesMap = @{other: @1};
    APFKillable(container, NULL, YES);
    NSCAssert(APFSeenKillable, @"其他应用必须原样放行");
    container.appLayout.itemsToLayoutAttributesMap = @{item: @1, other: @2};
    APFKillable(container, NULL, YES);
    NSCAssert(APFSeenKillable, @"混合布局不能影响其他应用");
    container.appLayout.itemsToLayoutAttributesMap = @{item: @1};
    atomic_store(&APFRequest, ((uint64_t)(getpid() + 1) << 32) | 28);
    APFKillable(container, NULL, YES);
    NSCAssert(APFSeenKillable, @"陈旧 PID 不能锁卡片");
    atomic_store(&APFRequest, pid | 28);
    NSCAssert(APFAccessory(item, NULL, nil) == 4 && APFAccessory(other, NULL, nil) == 77, @"运行标记只影响本应用");
    APFTestIconView *view = [APFTestIconView new]; view.icon = [APFTestIcon new]; view.icon.applicationBundleID = APFBundle;
    NSCAssert(APFViewAccessory(view, NULL) == 4, @"Dock 图标也要更新");
    APFTestPID = 0;
    NSCAssert(APFAccessory(item, NULL, nil) == 2 && APFViewAccessory(view, NULL) == 2, @"PID 为零必须显示停止，不因 processState 存在冒充运行");
    APFOptions = 0;
    NSCAssert(APFAccessory(item, NULL, nil) == 77 && APFViewAccessory(view, NULL) == 78, @"关闭标记必须恢复系统原值");
    APFOptions = 28;
    NSCAssert([APFDisplayName(item, NULL) containsString:@"已锁定"] && [APFDisplayName(other, NULL) isEqual:@"原始应用名称"], @"锁定名称只改本应用");
    APFOptions = 12;
    NSCAssert([APFDisplayName(item, NULL) isEqual:@"原始应用名称"], @"关闭锁定标记必须恢复原名称");
    APFOptions = 24;
    NSCAssert([APFDisplayName(item, NULL) isEqual:@"原始应用名称"], @"解除锁定不应留下锁定标记");
    APFTestPID = getpid();
    APFOptions = 0;
}

int main(void) {
    @autoreleasepool {
        APFReady = YES;
        APFTestPID = getpid();
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
        APFCheckProtection(pid);
        puts("通过：场景副本、应用隔离、关闭恢复、陈旧 PID、通知及 ABI；新增卡片锁定、混合布局放行、系统原值恢复、运行／停止与独立标记；不代表 SpringBoard 实际生效");
    }
    return 0;
}
