/* 本扩展独立运行；不向主应用链接分析引擎。 */
#import <Foundation/Foundation.h>
#include <signal.h>

extern volatile sig_atomic_t RAStopping;
enum { RAMaxFile = 48 * 1024 * 1024, RAMaxFrame = 1024 * 1024, RAMaxReply = 256 * 1024 };
double RANow(void);
void RAFail(NSString *code, NSString *message) __attribute__((noreturn));
BOOL RAInteger(id value, long long minimum, long long maximum);
BOOL RAIdentifier(id value);
NSString *RAHashFile(NSString *path);

@interface RACall : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *tool;
@property(nonatomic, strong) NSDictionary *arguments;
@property(nonatomic, strong) NSArray *references;
@property(atomic) BOOL cancelled;
@property(nonatomic) double deadline;
- (void)check;
@end

@interface RAAnalysis : NSObject
- (instancetype)initWithDirectory:(NSString *)directory idleSeconds:(double)idle;
- (NSDictionary *)run:(RACall *)call descriptor:(int)descriptor;
- (void)expire;
- (void)close;
@end

int RAServe(NSDictionary *manifest, NSString *directory, double idleSeconds);
