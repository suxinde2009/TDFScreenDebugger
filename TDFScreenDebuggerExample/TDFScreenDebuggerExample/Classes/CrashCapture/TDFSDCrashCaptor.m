//
//  TDFSDCrashCaptor.m
//  TDFScreenDebugger
//
//  Created by 开不了口的猫 on 2017/10/13.
//

#import "TDFSDCrashCaptor.h"
#import "TDFSDPersistenceSetting.h"
#import "TDFScreenDebuggerDefine.h"
#import "TDFSDCCCrashModel.h"
#import "TDFSDCrashCapturePresentationController.h"
#import "TDFSDTransitionAnimator.h"
#import <ReactiveObjC/ReactiveObjC.h>
#import <objc/runtime.h>
#import <signal.h>
#import <execinfo.h>

@interface TDFSDCrashCaptor () <UIViewControllerTransitioningDelegate>

@property (nonatomic, unsafe_unretained) NSUncaughtExceptionHandler *originHandler;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, assign) BOOL  needKeepAlive;
@property (nonatomic, assign) BOOL  needApplyForKeepingLifeCycle;

@end

@implementation TDFSDCrashCaptor

static const NSString *crashCallStackSymbolLocalizationFailDescription = @"fuzzy localization fail";
static const CGFloat  keepAliveReloadRenderingInterval  = 1 / 120.0f;

#pragma mark - life cycle

#if DEBUG
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        NSString *cachePath = SD_CRASH_CAPTOR_CACHE_REGISTERED_CLASSES_ARCHIVE_PATH;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSArray *registeredViewControllerHeirClasses = [NSArray array];
        
        if ([fileManager fileExistsAtPath:cachePath]) {
            registeredViewControllerHeirClasses = [NSKeyedUnarchiver unarchiveObjectWithFile:cachePath] ?: @[];
            hookAllViewControllerHeirsLifeCycle(registeredViewControllerHeirClasses);
            
            __weak NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            __block id token = [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    @synchronized(self) {
                        NSArray *newHeirClasses = [NSArray array];
                        obtainAllViewControllerHeirs(&newHeirClasses);
                        [NSKeyedArchiver archiveRootObject:newHeirClasses toFile:cachePath];
                    }
                });
                
                [center removeObserver:token];
            }];
        } else {
            obtainAllViewControllerHeirs(&registeredViewControllerHeirClasses);
            hookAllViewControllerHeirsLifeCycle(registeredViewControllerHeirClasses);
            [NSKeyedArchiver archiveRootObject:registeredViewControllerHeirClasses toFile:cachePath];
        }
    });
}

SD_CONSTRUCTOR_METHOD_DECLARE \
(SD_CONSTRUCTOR_METHOD_PRIORITY_BUILD_CACHE_CRASH, {
    // build exclusive crash folder in sdk's root folder
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *systemDicPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *crashFolderPath = [[systemDicPath stringByAppendingPathComponent:SD_LOCAL_CACHE_ROOT_FILE_FOLDER_NAME] stringByAppendingPathComponent:SD_CRASH_CAPTOR_CACHE_FILE_FOLDER_NAME];
    BOOL isDictonary;
    if ([fileManager fileExistsAtPath:crashFolderPath isDirectory:&isDictonary] && !isDictonary) {
        [fileManager removeItemAtPath:crashFolderPath error:nil];
    }
    if (![fileManager fileExistsAtPath:crashFolderPath]) {
        [fileManager createDirectoryAtPath:crashFolderPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
})

SD_CONSTRUCTOR_METHOD_DECLARE \
(SD_CONSTRUCTOR_METHOD_PRIORITY_CRASH_CAPTURE, {
    
    if ([[TDFSDPersistenceSetting sharedInstance] allowCrashCaptureFlag]) {
        // some sdk will dispatch `NSSetUncaughtExceptionHandler` method after about one second when runtime lib had started up
        // if these sdk don't register last exception-handler after their handler, we cannot handle exception normally
        // so we decide to delay the crash captor registration, only that we can handle crashs
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            
            // here we invoke some unsafe-async api, but if the crash occurs during controller's loading, this may lead to some dead cycle
            // so according to the reason above, we should intercept the crash individually when controller is loaded
            // in `+ load` method, we use runtime to hook all classes which inherit UIViewController and filter out system classes
            [[TDFSDCrashCaptor sharedInstance] thaw];
        });
    }
})
#endif

+ (instancetype)sharedInstance {
    static TDFSDCrashCaptor *sharedInstance = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _needApplyForKeepingLifeCycle = YES;
        
    }
    return self;
}

- (void)dealloc {
    [self freeze];
}

#pragma mark - interface methods
- (void)clearHistoryCrashLog {
    @synchronized(self) {
        NSString *cachePath = SD_CRASH_CAPTOR_CACHE_MODEL_ARCHIVE_PATH;
        NSMutableArray *cacheCrashModels = [NSKeyedUnarchiver unarchiveObjectWithFile:cachePath];
        if (!cacheCrashModels || cacheCrashModels.count == 0) {
            return;
        }
        [cacheCrashModels removeAllObjects];
        [NSKeyedArchiver archiveRootObject:cacheCrashModels toFile:cachePath];
    }
}

#pragma mark - TDFSDFunctionIOControlProtocol
- (void)thaw {
    NSArray *machSignals = exSignals();
    for (int index = 0; index < machSignals.count; index ++) {
        signal([machSignals[index] intValue], &machSignalExceptionHandler);
    }
    // Avoid calling dead loops
    if (self.originHandler != &ocExceptionHandler) {
        self.originHandler = NSGetUncaughtExceptionHandler();
    }
    NSSetUncaughtExceptionHandler(&ocExceptionHandler);
}

- (void)freeze {
    NSArray *machSignals = exSignals();
    for (int index = 0; index < machSignals.count; index ++) {
        signal([machSignals[index] intValue], SIG_DFL);
    }
    // In order to prevent multiple SDK capture exception in the case of other SDK can not receive callback,
    // we will register this exception to the next handler
    // https://nianxi.net/ios/ios-crash-reporter.html
    NSSetUncaughtExceptionHandler(self.originHandler);
}

#pragma mark - private
static void obtainAllViewControllerHeirs(NSArray **heirs) {
    unsigned int registerClassCount;
    Class *classes = objc_copyClassList(&registerClassCount);
    
    NSMutableArray *viewControllerHeirs = [NSMutableArray array];
    
    for (int i = 0; i < registerClassCount; i++) {
        Class class = classes[i];
        if (strcmp(class_getName(class), "_CNZombie_") == 0) continue;
        
        if (class_respondsToSelector(class, @selector(viewDidLoad))) {
            NSBundle *bundle = [NSBundle bundleForClass:class];
            if ([bundle isEqual:[NSBundle mainBundle]]) {
                NSLog(@"[TDFScreenDebugger.CrashCaptor.TraverseRegisteredClasses] %s\n", class_getName(class));
                [viewControllerHeirs addObject:class];
            }
        }
    }
    free(classes);
    *heirs = viewControllerHeirs;
}

static void hookAllViewControllerHeirsLifeCycle(NSArray *allHeirs) {
    [allHeirs enumerateObjectsUsingBlock:^(id  _Nonnull class, NSUInteger idx, BOOL * _Nonnull stop) {
        SEL selectors[] = {
            @selector(viewDidLoad),
            @selector(viewWillAppear:),
            @selector(viewDidAppear:),
            @selector(viewWillDisappear:),
            @selector(viewDidDisappear:),
            @selector(viewWillLayoutSubviews),
            @selector(viewDidLayoutSubviews)
        };
        
        for(int index = 0; index < sizeof(selectors)/sizeof(SEL); index ++) {
            SEL selector = selectors[index];
            if ([NSStringFromSelector(selector) hasSuffix:@":"]) {
                singleParmIMPReset(selector, class);
            } else {
                nullaParmIMPReset(selector, class);
            }
        }
    }];
}

static void nullaParmIMPReset(SEL selector, Class class) {
    Method method = class_getInstanceMethod(class, selector);
    void(*imp)(id, SEL, ...) = (typeof(imp))method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^(id target, SEL action){
        @try {
            imp(target, selector);
        } @catch (NSException *e) {
            if ([[TDFSDPersistenceSetting sharedInstance] allowCrashCaptureFlag]) {
                [TDFSDCrashCaptor sharedInstance].needApplyForKeepingLifeCycle = NO;
                ocExceptionHandler(e);
            } else {
                @throw e;
            }
        }
    }));
}

static void singleParmIMPReset(SEL selector, Class class) {
    Method method = class_getInstanceMethod(class, selector);
    void(*imp)(id, SEL, ...) = (typeof(imp))method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^(id target, SEL action, BOOL animated){
        @try {
            imp(target, selector, animated);
        } @catch (NSException *e) {
            if ([[TDFSDPersistenceSetting sharedInstance] allowCrashCaptureFlag]) {
                [TDFSDCrashCaptor sharedInstance].needApplyForKeepingLifeCycle = NO;
                ocExceptionHandler(e);
            } else {
                @throw e;
            }
        }
    }));
}

static void machSignalExceptionHandler(int signal) {
    const char* names[NSIG];
    names[SIGABRT] = "SIGABRT";
    names[SIGBUS] = "SIGBUS";
    names[SIGFPE] = "SIGFPE";
    names[SIGILL] = "SIGILL";
    names[SIGPIPE] = "SIGPIPE";
    names[SIGSEGV] = "SIGSEGV";
    
    const char* reasons[NSIG];
    reasons[SIGABRT] = "abort()";
    reasons[SIGBUS] = "bus error";
    reasons[SIGFPE] = "floating point exception";
    reasons[SIGILL] = "illegal instruction (not reset when caught)";
    reasons[SIGPIPE] = "write on a pipe with no one to read it";
    reasons[SIGSEGV] = "segmentation violation";
    
    TDFSDCCCrashModel *crash = [[TDFSDCCCrashModel alloc] init];
    crash.exceptionType = SD_CRASH_EXCEPTION_TYPE_SIGNAL;
    crash.exceptionTime = [[TDFSDCrashCaptor sharedInstance].dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:0]];
    crash.exceptionName = [NSString stringWithUTF8String:names[signal]];
    crash.exceptionReason = [NSString stringWithUTF8String:reasons[signal]];
    crash.fuzzyLocalization = (NSString *)crashCallStackSymbolLocalizationFailDescription;
    crash.exceptionCallStack = exceptionCallStackInfo();
    
    NSLog(@"%@", crash.debugDescription);
    
    if ([[TDFSDPersistenceSetting sharedInstance] needCacheCrashLogToSandBox]) {
        [[TDFSDCrashCaptor sharedInstance] performSelectorOnMainThread:@selector(cacheCrashLog:) withObject:crash waitUntilDone:YES];
    }
    
    showFriendlyCrashPresentation(crash, @(signal));
    applyForKeepingLifeCycle();
}

static void ocExceptionHandler(NSException *exception) {
    TDFSDCCCrashModel *crash = [[TDFSDCCCrashModel alloc] init];
    crash.exceptionType = SD_CRASH_EXCEPTION_TYPE_OC;
    crash.exceptionTime = [[TDFSDCrashCaptor sharedInstance].dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:0]];
    crash.exceptionName = [exception name];
    crash.exceptionReason = [exception reason];
    crash.fuzzyLocalization = crashFuzzyLocalization([exception callStackSymbols]);
    crash.exceptionCallStack = [NSString stringWithFormat:@"%@", [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
    
    NSLog(@"%@", crash.debugDescription);

    if ([[TDFSDPersistenceSetting sharedInstance] needCacheCrashLogToSandBox]) {
        [[TDFSDCrashCaptor sharedInstance] performSelectorOnMainThread:@selector(cacheCrashLog:) withObject:crash waitUntilDone:YES];
    }

    showFriendlyCrashPresentation(crash, exception);
    if ([[TDFSDCrashCaptor sharedInstance] needApplyForKeepingLifeCycle]) {
        applyForKeepingLifeCycle();
    } else {
        [TDFSDCrashCaptor sharedInstance].needApplyForKeepingLifeCycle = YES;
    }
}

static NSArray<NSNumber *> * exSignals(void) {
    return @[
            @(SIGABRT),
            @(SIGBUS),
            @(SIGFPE),
            @(SIGILL),
            @(SIGPIPE),
            @(SIGSEGV)
           ];
}

static NSString * exceptionCallStackInfo(void) {
    void* callstack[128];
    const int frames = backtrace(callstack, 128);
    char **symbols = backtrace_symbols(callstack, frames);
    
    NSMutableString *callstackInfo = [NSMutableString string];
    
    for (int index = 0; index < frames; index ++) {
        [callstackInfo appendFormat:@"\t%@\n", [NSString stringWithUTF8String:symbols[index]]];
    }
    
    free(symbols);
    return callstackInfo;
}

static NSString *crashFuzzyLocalization(NSArray<NSString *> *callStackSymbols) {
    __block NSString *fuzzyLocalization = nil;
    NSString *regularExpressionFormatStr = @"[-\\+]\\[.+\\]";
    
    NSRegularExpression *regularExp = [[NSRegularExpression alloc] initWithPattern:regularExpressionFormatStr options:NSRegularExpressionCaseInsensitive error:nil];
    
    for (int index = 2; index < callStackSymbols.count; index++) {
        NSString *callStackSymbol = callStackSymbols[index];
        
        [regularExp enumerateMatchesInString:callStackSymbol options:NSMatchingReportProgress range:NSMakeRange(0, callStackSymbol.length) usingBlock:^(NSTextCheckingResult * _Nullable result, NSMatchingFlags flags, BOOL * _Nonnull stop) {
            if (result) {
                NSString* callStackSymbolMsg = [callStackSymbol substringWithRange:result.range];
                NSString *className = [callStackSymbolMsg componentsSeparatedByString:@" "].firstObject;
                className = [className componentsSeparatedByString:@"["].lastObject;
                NSBundle *bundle = [NSBundle bundleForClass:NSClassFromString(className)];
                
                // filter out system class
                if ([bundle isEqual:[NSBundle mainBundle]]) {
                    fuzzyLocalization = callStackSymbolMsg;
                }
                *stop = YES;
            }
        }];
        
        if (fuzzyLocalization.length) break;
    }
    
    return fuzzyLocalization ?: crashCallStackSymbolLocalizationFailDescription;
}

static void showFriendlyCrashPresentation(TDFSDCCCrashModel *crash, id addition) {
    // find out the toppest and useable window
    NSArray<UIWindow *> *windows = [[UIApplication sharedApplication] windows];
    UIWindow *effectiveWindow = [[[[windows.rac_sequence
    filter:^BOOL(id  _Nullable value) {
        return ![(UIWindow *)value isHidden] && [(UIWindow *)value alpha] != 0;
    }]
    array]
    sortedArrayUsingComparator:^NSComparisonResult(UIWindow * _Nonnull obj1, UIWindow * _Nonnull obj2) {
        if (obj1.windowLevel > obj2.windowLevel) {
            return NSOrderedAscending;
        } else {
            return NSOrderedDescending;
        }
    }]
    firstObject];

    TDFSDCrashCapturePresentationController *p = [[TDFSDCrashCapturePresentationController alloc] init];
    p.crashInfo = crash;
    p.exportProxy = [RACSubject subject];
    p.terminateProxy = [RACSubject subject];
    [p.exportProxy subscribeNext:^(id  _Nullable x) {
        ////// export code //////
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            void(^done)() = x;
            done();
        });
    }];
    [p.terminateProxy subscribeNext:^(TDFSDCCCrashModel * _Nullable x) {
        TDFSDCrashCaptor *captor = [TDFSDCrashCaptor sharedInstance];
        [captor freeze];
        captor.needKeepAlive = NO;
        if ([x.exceptionType isEqualToString:SD_CRASH_EXCEPTION_TYPE_OC]) {
            NSException *exc = addition;
            [exc raise];
        }
        else if ([x.exceptionType isEqualToString:SD_CRASH_EXCEPTION_TYPE_SIGNAL]) {
            int signal = [addition intValue];
            kill(getpid(), signal);
        }
    }];
    p.transitioningDelegate = [TDFSDCrashCaptor sharedInstance];
    if (effectiveWindow.rootViewController.presentedViewController) {
        [effectiveWindow.rootViewController.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    }
    [effectiveWindow.rootViewController presentViewController:p animated:YES completion:nil];
}

static void applyForKeepingLifeCycle(void) {
    CFRunLoopRef runloop = CFRunLoopGetCurrent();
    CFArrayRef allModesRef = CFRunLoopCopyAllModes(runloop);
    
    TDFSDCrashCaptor *captor = [TDFSDCrashCaptor sharedInstance];
    
    @synchronized(captor) {
        captor.needKeepAlive = YES;
    }
    
    // let app continue to run
    while (captor.needKeepAlive) {
        for (NSString *mode in (__bridge_transfer NSArray *)allModesRef) {
            if ([mode isEqualToString:(NSString *)kCFRunLoopCommonModes]) {
                continue;
            }
            CFStringRef modeRef  = (__bridge CFStringRef)mode;
            CFRunLoopRunInMode(modeRef, keepAliveReloadRenderingInterval, false);
        }
    }
}

- (void)cacheCrashLog:(TDFSDCCCrashModel *)model {
    @synchronized(self) {
        NSString *cachePath = SD_CRASH_CAPTOR_CACHE_MODEL_ARCHIVE_PATH;
        NSMutableArray *cacheCrashModels = [NSKeyedUnarchiver unarchiveObjectWithFile:cachePath];
        if (!cacheCrashModels) {
            cacheCrashModels = @[].mutableCopy;
        }
        if (![cacheCrashModels containsObject:model]) {
            [cacheCrashModels addObject:model];
        }
        BOOL isSuccess = [NSKeyedArchiver archiveRootObject:cacheCrashModels toFile:cachePath];
        NSLog(@"[TDFScreenDebugger.CrashCaptor.SaveCrashLog] %@", isSuccess ? @"result_success" : @"result_failure");
    }
}

#pragma mark - UIViewControllerTransitioningDelegate
- (nullable id <UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source {
    return [TDFSDTransitionAnimator new];
}

- (nullable id <UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    return [TDFSDTransitionAnimator new];
}

#pragma mark - getter
- (NSDateFormatter *)dateFormatter {
    if (!_dateFormatter) {
        _dateFormatter = [[NSDateFormatter alloc] init];
        [_dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    }
    return _dateFormatter;
}

@end