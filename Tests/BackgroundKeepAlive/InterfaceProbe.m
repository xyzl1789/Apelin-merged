#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

int main(void) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/UIKitServices.framework/UIKitServices", RTLD_LAZY);
        const char *classes[] = {"UIMutableApplicationSceneSettings", "FBSMutableSceneSettings", "FBSSceneSettings"};
        const char *selectors[] = {"setForeground:", "setBackgrounded:", "setDeactivationReasons:", "foreground", "isForeground", "isBackgrounded", "mutableCopyWithZone:"};
        for (unsigned i = 0; i < 3; i++) {
            Class cls = objc_getClass(classes[i]);
            printf("%s 存在=%d，NSMutableCopying=%d\n", classes[i], cls != Nil, class_conformsToProtocol(cls, @protocol(NSMutableCopying)));
            for (unsigned j = 0; j < 7; j++) {
                Method method = class_getInstanceMethod(cls, sel_registerName(selectors[j]));
                printf("  %s: %s\n", selectors[j], method ? method_getTypeEncoding(method) : "缺失");
            }
        }
    }
    return 0;
}
