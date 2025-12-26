// AliSniffer.m (popup-only, no floating button)
// 仅用于你们自有页面/自有服务器的调试抓取（NSURLSession / WKWebView / AVPlayer）。
// 编译：-fobjc-arc，arm64，iOS 11+，dylib
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - Config

// 只在这些 host 命中时“自动启用”（改成你们页面域名即可）
static NSArray<NSString *> *AS_TargetHosts(void) {
    return @[
        @"ced.wtyibxc.cn",
        @"app.kuniunet.com",
        @"kuniunet.com",
        // @"your.domain.com",
    ];
}

// 是否只抓“媒体相关”URL；想抓完整请求可改成 NO
static BOOL AS_OnlyMediaURLs = YES;

// 媒体 URL 识别：m3u8/mpd/m4s/ts/mp4/flv/rtmp…（可自行增删）
static BOOL AS_IsMediaURL(NSString *u) {
    if (!u.length) return NO;
    static NSRegularExpression *re = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)(\\.m3u8(\\?|$)|\\.mpd(\\?|$)|\\.m4s(\\?|$)|\\.ts(\\?|$)|\\.mp4(\\?|$)|\\.flv(\\?|$)|^rtmps?:\\/\\/)"
                                                      options:0 error:nil];
    });
    return [re numberOfMatchesInString:u options:0 range:NSMakeRange(0, u.length)] > 0;
}

static BOOL AS_HostMatched(NSString *host) {
    if (!host.length) return NO;
    for (NSString *h in AS_TargetHosts()) {
        if ([host isEqualToString:h]) return YES;
        if ([host hasSuffix:[@"." stringByAppendingString:h]]) return YES;
    }
    return NO;
}

#pragma mark - State

static BOOL gAS_Enabled = YES;              // 你说不需要开关，这里默认一直开
static BOOL gAS_EnteredTargetPage = NO;     // 是否进入过目标域名页面
static NSMutableArray<NSString *> *gAS_Captured = nil;

static void AS_PushCaptured(NSString *line) {
    if (!line.length) return;
    if (!gAS_Captured) gAS_Captured = [NSMutableArray array];
    NSString *last = gAS_Captured.lastObject;
    if ([last isEqualToString:line]) return;
    [gAS_Captured addObject:line];
    if (gAS_Captured.count > 200) [gAS_Captured removeObjectAtIndex:0];
}

#pragma mark - UI helpers (popup)

static UIViewController *AS_TopVC(void) {
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = key.rootViewController ?: UIApplication.sharedApplication.delegate.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// 弹窗节流：避免短时间内大量弹窗卡死
static NSTimeInterval gAS_LastAlertTS = 0;

static void AS_ShowAlert(NSString *title, NSString *message, BOOL allowCopyLatest) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = AS_TopVC();
        if (!vc) return;

        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - gAS_LastAlertTS < 0.8) return; // 0.8s 内只弹一次
        gAS_LastAlertTS = now;

        // 如果当前已经有弹窗在展示，先不打扰（避免堆叠）
        if ([vc isKindOfClass:[UIAlertController class]]) return;
        if (vc.presentedViewController && [vc.presentedViewController isKindOfClass:[UIAlertController class]]) return;

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title ?: @"AliSniffer"
                                                                    message:message ?: @""
                                                             preferredStyle:UIAlertControllerStyleAlert];

        if (allowCopyLatest) {
            [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
                UIPasteboard.generalPasteboard.string = message ?: @"";
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

        [vc presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - Report

static void AS_ReportLine(NSString *line, NSString *src) {
    if (!line.length) return;
    NSString *msg = src.length ? [NSString stringWithFormat:@"[%@]\n%@", src, line] : line;

    NSLog(@"[AliSniffer] %@", msg);
    AS_PushCaptured(msg);

    // 直接弹窗提示（你要求：全部弹窗提示）
    AS_ShowAlert(@"AliSniffer 抓到URL", msg, YES);

    @try {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AliSnifferFound"
                                                            object:nil
                                                          userInfo:@{@"line": msg}];
    } @catch (...) {}
}

static NSString *AS_ShortBody(NSData *body) {
    if (!body.length) return nil;
    if (body.length > 8 * 1024) return [NSString stringWithFormat:@"<body %lu bytes>", (unsigned long)body.length];
    NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!s.length) return [NSString stringWithFormat:@"<body %lu bytes>", (unsigned long)body.length];
    return s;
}

static BOOL AS_ShouldCaptureURL(NSURL *url) {
    if (!gAS_Enabled || !url) return NO;
    if (!AS_HostMatched(url.host ?: @"")) return NO;
    if (!gAS_EnteredTargetPage) return NO; // 只在“进入目标页面后”才开始抓
    NSString *u = url.absoluteString ?: @"";
    if (AS_OnlyMediaURLs) return AS_IsMediaURL(u);
    return YES;
}

#pragma mark - Swizzle helper

static void AS_Swizzle(Class c, SEL sel, IMP newImp, IMP *origOut) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - NSURLSession hooks (request + headers + body)

static id (*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *);
static id swz_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    // 这里不直接判定“进入页面”，因为很多请求可能早于页面进入。由 WKWebView loadRequest 触发进入标记。
    return orig_dataTaskWithRequest ? orig_dataTaskWithRequest(self, _cmd, request) : nil;
}

static id (*orig_uploadTaskWithRequest_fromData)(id, SEL, NSURLRequest *, NSData *);
static id swz_uploadTaskWithRequest_fromData(id self, SEL _cmd, NSURLRequest *request, NSData *data) {
    return orig_uploadTaskWithRequest_fromData ? orig_uploadTaskWithRequest_fromData(self, _cmd, request, data) : nil;
}

static void (*orig_task_resume)(id, SEL);
static void swz_task_resume(id self, SEL _cmd) {
    @try {
        NSURLRequest *r = nil;
        @try { r = [self respondsToSelector:@selector(currentRequest)] ? [self performSelector:@selector(currentRequest)] : nil; } @catch(...) {}

        if (r.URL && AS_ShouldCaptureURL(r.URL)) {
            NSString *method = r.HTTPMethod ?: @"GET";
            NSDictionary *h = r.allHTTPHeaderFields ?: @{};
            NSString *b = AS_ShortBody(r.HTTPBody);

            NSString *line = b.length
                ? [NSString stringWithFormat:@"%@ %@\nHeaders:%@\nBody:%@", method, r.URL.absoluteString, h, b]
                : [NSString stringWithFormat:@"%@ %@\nHeaders:%@", method, r.URL.absoluteString, h];

            NSNumber *done = objc_getAssociatedObject(self, "as_reported");
            if (!done.boolValue) {
                AS_ReportLine(line, @"NSURLSession");
                objc_setAssociatedObject(self, "as_reported", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    } @catch(...) {}
    if (orig_task_resume) orig_task_resume(self, _cmd);
}

__attribute__((constructor))
static void AS_InstallSessionHooks(void) {
    @autoreleasepool {
        Class S = NSClassFromString(@"NSURLSession");
        if (S) {
            AS_Swizzle(S, @selector(dataTaskWithRequest:), (IMP)swz_dataTaskWithRequest, (IMP *)&orig_dataTaskWithRequest);
            AS_Swizzle(S, @selector(uploadTaskWithRequest:fromData:),
                       (IMP)swz_uploadTaskWithRequest_fromData, (IMP *)&orig_uploadTaskWithRequest_fromData);
        }
        Class T = NSClassFromString(@"NSURLSessionTask");
        if (T) AS_Swizzle(T, @selector(resume), (IMP)swz_task_resume, (IMP *)&orig_task_resume);

        AS_ShowAlert(@"AliSniffer", @"注入成功（NSURLSession 已Hook）", NO);
        NSLog(@"[AliSniffer] NSURLSession hooks installed");
    }
}

#pragma mark - AVPlayerItem AccessLog (兜底)

static void AS_ObserveAccessLog(AVPlayerItem *item) {
    if (!item) return;
    @try {
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemNewAccessLogEntryNotification
                                                          object:item
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            @try {
                if (!gAS_Enabled || !gAS_EnteredTargetPage) return;
                AVPlayerItemAccessLog *log = item.accessLog;
                id ev = log.events.lastObject;
                NSString *uri = nil;
                if ([ev respondsToSelector:NSSelectorFromString(@"URI")]) uri = [ev valueForKey:@"URI"];
                if (uri.length) {
                    NSURL *u = [NSURL URLWithString:uri];
                    if (u && AS_ShouldCaptureURL(u)) {
                        AS_ReportLine([NSString stringWithFormat:@"AVAccessLog URI: %@", uri], @"AVPlayer");
                    }
                }
            } @catch(...) {}
        }];
    } @catch(...) {}
}

static id (*orig_item_initWithURL)(id, SEL, NSURL *);
static id swz_item_initWithURL(id self, SEL _cmd, NSURL *URL) {
    id item = orig_item_initWithURL ? orig_item_initWithURL(self, _cmd, URL) : nil;
    if (item) AS_ObserveAccessLog((AVPlayerItem *)item);
    return item;
}

__attribute__((constructor))
static void AS_InstallAVHooks(void) {
    @autoreleasepool {
        Class C = NSClassFromString(@"AVPlayerItem");
        Method m = class_getInstanceMethod(C, @selector(initWithURL:));
        if (m) {
            orig_item_initWithURL = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)swz_item_initWithURL);
        }
        NSLog(@"[AliSniffer] AV hooks installed");
    }
}

#pragma mark - WKWebView inject (resource sniff + mark entered page)

@interface ASWKHandler : NSObject <WKScriptMessageHandler> @end
@implementation ASWKHandler
- (void)userContentController:(WKUserContentController *)uc didReceiveScriptMessage:(WKScriptMessage *)m {
    if (![m.name isEqualToString:@"_AS"]) return;
    if (![m.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *d = (NSDictionary *)m.body;
    NSString *type = d[@"t"];
    NSString *url  = d[@"u"];
    if (!url.length) return;

    // 资源抓取
    if (!AS_OnlyMediaURLs || AS_IsMediaURL(url)) {
        NSURL *u = [NSURL URLWithString:url];
        if (u && AS_ShouldCaptureURL(u)) {
            AS_ReportLine([NSString stringWithFormat:@"WK(%@): %@", type ?: @"?", url], @"WKWebView");
        }
    }
}
@end

static void AS_AddWKScripts(WKWebViewConfiguration *cfg) {
    if (!cfg) return;
    static void *kKey = &kKey;
    if (objc_getAssociatedObject(cfg, kKey)) return;
    objc_setAssociatedObject(cfg, kKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ASWKHandler *h = [ASWKHandler new];
    @try { [cfg.userContentController addScriptMessageHandler:h name:@"_AS"]; } @catch (...) {}

    NSData *json = [NSJSONSerialization dataWithJSONObject:AS_TargetHosts() options:0 error:nil];
    NSString *targets = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"[]";

    NSString *js =
    [NSString stringWithFormat:
     @"(function(){try{"
      "function post(t,u){try{window.webkit.messageHandlers._AS.postMessage({t:t,u:String(u||'')});}catch(e){}}"
      "function host(){try{return location.host||'';}catch(e){return ''}}"
      "function matchHost(){var h=host();var targets=%@;for(var i=0;i<targets.length;i++){var th=targets[i];if(h===th||h.endsWith('.'+th))return true;}return false;}"
      "if(matchHost()) { post('page', location.href); }"
      "var _push=history.pushState;history.pushState=function(){var r=_push.apply(this,arguments);try{if(matchHost())post('nav',location.href);}catch(e){}return r;};"
      "window.addEventListener('popstate',function(){try{if(matchHost())post('nav',location.href);}catch(e){}});"
      "if(window.fetch){var _f=window.fetch;window.fetch=function(){try{post('fetch_req',arguments[0]);}catch(e){}"
        "return _f.apply(this,arguments).then(function(r){try{if(r&&r.url)post('fetch_res',r.url);}catch(e){}return r;});};}"
      "if(window.XMLHttpRequest){var X=window.XMLHttpRequest;var o=X.prototype.open;X.prototype.open=function(m,u){try{post('xhr_open',u);}catch(e){}return o.apply(this,arguments);};}"
      "setInterval(function(){try{if(!matchHost())return;var es=performance.getEntriesByType('resource')||[];"
        "for(var i=Math.max(0,es.length-30);i<es.length;i++){var e=es[i];if(e&&e.name)post('perf',e.name);}"
      "}catch(e){}},1200);"
     "}catch(e){}})();", targets];

    WKUserScript *sc = [[WKUserScript alloc] initWithSource:js
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO];
    @try { [cfg.userContentController addUserScript:sc]; } @catch (...) {}
}

static id (*orig_wk_init_frame)(id, SEL, CGRect, WKWebViewConfiguration *);
static id swz_wk_init_frame(id self, SEL _cmd, CGRect frame, WKWebViewConfiguration *cfg) {
    if (cfg) AS_AddWKScripts(cfg);
    return orig_wk_init_frame(self, _cmd, frame, cfg);
}

static void (*orig_wk_loadRequest)(id, SEL, NSURLRequest *);
static void swz_wk_loadRequest(WKWebView *self, SEL _cmd, NSURLRequest *req) {
    @try {
        NSString *host = req.URL.host ?: @"";
        if (AS_HostMatched(host)) {
            if (!gAS_EnteredTargetPage) {
                gAS_EnteredTargetPage = YES;
                AS_ShowAlert(@"AliSniffer", [NSString stringWithFormat:@"进入页面：%@\n开始抓取…", host], NO);
            }
        }
    } @catch(...) {}
    if (orig_wk_loadRequest) orig_wk_loadRequest(self, _cmd, req);
}

__attribute__((constructor))
static void AS_InstallWKHooks(void) {
    @autoreleasepool {
        Class C = NSClassFromString(@"WKWebView");
        if (!C) return;

        Method m1 = class_getInstanceMethod(C, @selector(initWithFrame:configuration:));
        if (m1) {
            orig_wk_init_frame = (void *)method_getImplementation(m1);
            method_setImplementation(m1, (IMP)swz_wk_init_frame);
        }

        Method m2 = class_getInstanceMethod(C, @selector(loadRequest:));
        if (m2) {
            orig_wk_loadRequest = (void *)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)swz_wk_loadRequest);
        }

        NSLog(@"[AliSniffer] WK hooks installed");
    }
}
