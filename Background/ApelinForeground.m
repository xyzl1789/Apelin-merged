/*
 * 基于 Immortalizer 的场景保持及前台通知机制适配。
 * Copyright (C) 2024 Serge Alagon
 * Copyright (C) 2026 Apelin-merged contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 * 修改日期：2026-11-25；目标限定、场景副本恢复、通知开关及 ABI 核验。
 * 本程序可按 GNU GPL 第3版或更新版本再分发或修改，不提供任何担保，
 * 包括适销性或特定用途适用性的默示担保；完整条款见同目录 LICENSE。
 * 本文件属于独立 SpringBoard 模块，不链接进 App 或 apelind。
 */
#import <Foundation/Foundation.h>
#ifndef APELIN_FOREGROUND_TEST
#import <UIKit/UIKit.h>
#endif
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <os/log.h>
#import <dlfcn.h>
#import <stdatomic.h>

static NSString *const APFBundle = @"wiki.qaq.apelin";
static const char *APFRequestName = "com.xyzl.apelin.foreground.request";
static const char *APFStatusName = "com.xyzl.apelin.foreground.status";
static atomic_uint_fast64_t APFRequest;
static atomic_bool APFApplied;
static BOOL APFReady;
static int APFRequestToken = -1, APFStatusToken = -1;
#ifndef APELIN_FOREGROUND_TEST
static int APFLockToken = -1;
#endif
static NSMapTable *APFScenes;
static void (*APFOriginalScene)(id, SEL, id, id, id);
static void (*APFOriginalNotice)(id, SEL, id, id, id);
static void (*APFOriginalDisplay)(id, SEL, id);
static void (*APFOriginalExit)(id, SEL, id);

static os_log_t APFLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.xyzl.apelin.foreground", "场景保活"); });
    return log;
}

// 每个私有调用先检查 ABI；不猜测不存在的方法或返回值。
static BOOL APFSignature(Class cls, SEL selector, const char *result, NSArray<NSString *> *args) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != args.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL matches = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger i = 0; matches && i < args.count; i++) {
        type = method_copyArgumentType(method, (unsigned)i + 2);
        matches = type && strcmp(type, args[i].UTF8String) == 0;
        free(type);
    }
    return matches;
}

static id APFObject(id object, const char *name) {
    SEL selector = sel_registerName(name);
    if (!object || !APFSignature(object_getClass(object), selector, "@", @[])) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL APFTarget(id scene) {
    return [APFObject(APFObject(scene, "clientProcess"), "bundleIdentifier") isEqual:APFBundle];
}

static BOOL APFVisible(void) {
#ifdef APELIN_FOREGROUND_TEST
    return NO;
#else
    id app = APFObject(UIApplication.sharedApplication, "_accessibilityFrontMostApplication");
    id manager = APFObject((id)objc_getClass("SBLockScreenManager"), "sharedInstance");
    SEL locked = sel_registerName("isUILocked");
    // 无法核实锁屏状态时按不可见处理，不冒充真实前台。
    if (!manager || !APFSignature(object_getClass(manager), locked, "B", @[])) return NO;
    BOOL isLocked = ((BOOL (*)(id, SEL))objc_msgSend)(manager, locked);
    return !isLocked && [APFObject(app, "bundleIdentifier") isEqual:APFBundle];
#endif
}

static BOOL APFLiveRequest(void) {
    uint64_t request = atomic_load(&APFRequest);
    id controller = APFObject((id)objc_getClass("SBApplicationController"), "sharedInstance");
    SEL find = sel_registerName("applicationWithBundleIdentifier:");
    if (!controller || !APFSignature(object_getClass(controller), find, "@", @[@"@"])) return NO;
    id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, find, APFBundle);
    id process = APFObject(app, "processState");
    SEL pid = sel_registerName("pid");
    if (!process || !APFSignature(object_getClass(process), pid, "i", @[])) return NO;
    int actualPID = ((int (*)(id, SEL))objc_msgSend)(process, pid);
    return actualPID > 0 && (uint32_t)(request >> 32) == (uint32_t)actualPID;
}

static BOOL APFHolding(void) {
    return APFReady && (atomic_load(&APFRequest) & 1) && APFLiveRequest();
}

static void APFPublishStatus(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ APFPublishStatus(); });
        return;
    }
    if (APFStatusToken < 0) return;
    uint64_t request = atomic_load(&APFRequest);
    uint64_t flags = (APFReady ? 1 : 0) | (atomic_load(&APFApplied) ? 2 : 0) | (APFVisible() ? 4 : 0);
    notify_set_state(APFStatusToken, (request & UINT64_C(0xffffffff00000000)) | flags);
    notify_post(APFStatusName);
}

// 与原版不同：只改本应用的场景副本，保留几何、键盘、旋转、transition 和 completion。
// 不全局拦截 setDeactivationReasons，也不直接吞掉整次 updateSettings。
static id APFForegroundSettings(id settings) {
    id copy = [settings respondsToSelector:@selector(mutableCopyWithZone:)] ? [settings mutableCopy] : nil;
    SEL foreground = sel_registerName("setForeground:");
    SEL backgrounded = sel_registerName("setBackgrounded:");
    SEL reasons = sel_registerName("setDeactivationReasons:");
    Class cls = object_getClass(copy);
    if (!copy || copy == settings ||
        !APFSignature(cls, foreground, "v", @[@"B"]) ||
        !APFSignature(cls, backgrounded, "v", @[@"B"]) ||
        !APFSignature(cls, reasons, "v", @[@"Q"])) return nil;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(copy, foreground, YES);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(copy, backgrounded, NO);
    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(copy, reasons, 0);
    return copy;
}

static void APFRestoreScenes(void);

static void APFSceneUpdate(id self, SEL cmd, id settings, id transition, id completion) {
    if (!APFTarget(self)) {
        APFOriginalScene(self, cmd, settings, transition, completion);
        return;
    }
    // 第一次更新必须原样完成配置，再在下一轮应用保持。
    BOOL configured;
    @synchronized (APFScenes) {
        configured = [APFScenes objectForKey:self] != nil;
        if (settings) [APFScenes setObject:[settings copy] forKey:self];
    }
    id replacement = configured && APFHolding() ? APFForegroundSettings(settings) : nil;
    BOOL previouslyApplied = atomic_exchange(&APFApplied, replacement != nil);
    APFOriginalScene(self, cmd, replacement ?: settings, transition, completion);
    if (!settings) atomic_store(&APFApplied, false);
    if (previouslyApplied != (replacement != nil)) {
        os_log(APFLog(), "本应用场景保持状态变化：%{public}s", replacement ? "已应用" : "已恢复");
    }
    APFPublishStatus();
    if (!configured && settings && APFHolding()) {
        dispatch_async(dispatch_get_main_queue(), ^{ APFRestoreScenes(); APFPublishStatus(); });
    }
}

static void APFNotificationState(id server, BOOL background) {
    SEL selector = sel_registerName("_didChangeApplicationState:forBundleIdentifier:");
    if (APFSignature(object_getClass(server), selector, "v", @[@"I", @"@"])) {
        ((void (*)(id, SEL, unsigned, id))objc_msgSend)(server, selector, background ? 4 : 8, APFBundle);
    }
}

static void APFNotice(id self, SEL cmd, id notification, id bundle, id completion) {
    if ([bundle isEqual:APFBundle] && (atomic_load(&APFRequest) & 2) && APFLiveRequest()) {
        // 原版的“启用前台通知”：只调整本应用在通知服务中的前后台判定。
        // 不绕过通知授权、专注模式、静音或系统通知样式。
        APFNotificationState(self, YES);
        os_log(APFLog(), "已为本应用保留前台通知递送");
    }
    APFOriginalNotice(self, cmd, notification, bundle, completion);
}

static void APFRestoreScenes(void) {
    NSArray *scenes;
    @synchronized (APFScenes) { scenes = APFScenes.keyEnumerator.allObjects; }
    for (id scene in scenes) {
        id settings;
        @synchronized (APFScenes) { settings = [APFScenes objectForKey:scene]; }
        if (!settings || !APFTarget(scene)) continue;
        id replacement = APFHolding() ? APFForegroundSettings(settings) : nil;
        APFOriginalScene(scene, sel_registerName("updateSettings:withTransitionContext:completion:"),
                         replacement ?: settings, nil, nil);
        atomic_store(&APFApplied, replacement != nil);
    }
    if (!APFHolding()) atomic_store(&APFApplied, false);
}

static void APFReadRequest(void) {
    uint64_t request = 0;
    if (APFRequestToken < 0 || notify_get_state(APFRequestToken, &request) != NOTIFY_STATUS_OK) request = 0;
    uint64_t previous = atomic_exchange(&APFRequest, request);
    if (previous != request && APFReady) {
        APFRestoreScenes();
        id server = APFObject((id)objc_getClass("UNSUserNotificationServer"), "sharedInstance");
        BOOL forceNotifications = (request & 2) && APFLiveRequest();
        APFNotificationState(server, forceNotifications || (!APFHolding() && !APFVisible()));
        os_log(APFLog(), "后台开关=%d，前台通知=%d", (request & 1) != 0, (request & 2) != 0);
    }
    APFPublishStatus();
}

static void APFDisplay(id self, SEL cmd, id display) {
    APFOriginalDisplay(self, cmd, display);
    dispatch_async(dispatch_get_main_queue(), ^{ APFPublishStatus(); });
}

static void APFExit(id self, SEL cmd, id context) {
    BOOL target = [APFObject(self, "bundleIdentifier") isEqual:APFBundle];
    APFOriginalExit(self, cmd, context);
    if (target) {
        atomic_store(&APFRequest, 0);
        atomic_store(&APFApplied, false);
        @synchronized (APFScenes) { [APFScenes removeAllObjects]; }
        APFPublishStatus();
    }
}

#ifndef APELIN_FOREGROUND_TEST
__attribute__((constructor)) static void APFInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        APFScenes = [NSMapTable weakToStrongObjectsMapTable];
        typedef void (*Hook)(Class, SEL, IMP, IMP *);
        Hook hook = (Hook)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        Class scene = objc_getClass("FBScene"), server = objc_getClass("UNSUserNotificationServer");
        Class springboard = objc_getClass("SpringBoard"), application = objc_getClass("SBApplication");
        SEL update = sel_registerName("updateSettings:withTransitionContext:completion:");
        SEL notice = sel_registerName("willPresentNotification:forBundleIdentifier:withCompletionHandler:");
        SEL display = sel_registerName("frontDisplayDidChange:"), exited = sel_registerName("_didExitWithContext:");
        APFReady = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 16 && hook && APFSignature(scene, update, "v", @[@"@", @"@", @"@?"]) &&
            APFSignature(server, notice, "v", @[@"@", @"@", @"@?"]) &&
            APFSignature(server, sel_registerName("_didChangeApplicationState:forBundleIdentifier:"), "v", @[@"I", @"@"]) &&
            APFSignature(springboard, display, "v", @[@"@"]) && APFSignature(application, exited, "v", @[@"@"]);
        if (APFReady) {
            hook(scene, update, (IMP)APFSceneUpdate, (IMP *)&APFOriginalScene);
            hook(server, notice, (IMP)APFNotice, (IMP *)&APFOriginalNotice);
            hook(springboard, display, (IMP)APFDisplay, (IMP *)&APFOriginalDisplay);
            hook(application, exited, (IMP)APFExit, (IMP *)&APFOriginalExit);
        } else {
            os_log_error(APFLog(), "场景保活模块接口不兼容，未安装任何 hook");
        }
        notify_register_check(APFStatusName, &APFStatusToken);
        notify_register_dispatch(APFRequestName, &APFRequestToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            APFReadRequest();
        });
        // 锁屏事件只用于可见性判定，不改变系统锁屏状态。
        notify_register_dispatch("com.apple.springboard.lockstate", &APFLockToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            APFPublishStatus();
        });
        APFReadRequest();
        os_log(APFLog(), "ApelinLoaded: SpringBoard 场景保活模块已启动，接口兼容=%d", APFReady);
    });
}
#endif
