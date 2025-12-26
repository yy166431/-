// AliSniffer.m (fixed build errors + auto-enable on target host)
// 仅用于你们自有页面/自有服务器的调试抓取（NSURLSession/WKWebView/AVPlayer）。
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

// 媒体 URL 识别：m3u8/mpd/m4s/ts/mp4/flv/rtmp/ws-flv…（可自行增删）
static BOOL AS_IsMediaURL(NSString *u) {
    if (!u.length) return NO;
    static NSRegularExpression *re = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?i)(\\.m3u8(\\?|$)|\\.mpd(\\?|$)|\\.m4s(\\?|$)|\\.ts(\\?|$)|\\.mp4(\\?|$)|\\.flv(\\?|$)|^rtmps?:\\/\\/|^wss?:\\/\\/.*\\.flv)"
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

#pragma mark - Runtime Switch

static BOOL gAS_Enabled = NO;
static BOOL gAS_AutoEnabledByHost = NO;

static void AS_SetEnabled(BOOL en);

#pragma mark - UI (floating button)

@interface ASFloatButton : UIButton @end
@implementation ASFloatButton @end

@interface ASOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *as_touchView; // only this view receives touches
@end
@implementation ASOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Only let touches land on the floating button; otherwise pass through to WeChat.
    UIView *v = self.as_touchView;
    if (!v || v.hidden || v.alpha < 0.01 || !v.userInteractionEnabled) return nil;
    CGPoint p = [v convertPoint:point fromView:self];
    if ([v pointInside:p withEvent:event]) {
        return [v hitTest:p withEvent:event];
    }
    return nil;
}
@end


static UIWindow *gAS_OverlayWindow = nil;
static ASFloatButton *gAS_Button = nil;

static UIViewController *AS_TopVC(void) {
    UIWindow *key = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = key.rootViewController ?: UIApplication.sharedApplication.delegate.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void AS_ShowToast(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = AS_TopVC();
        if (!vc) return;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0,0,0,0)];
        lab.text = text ?: @"";
        lab.numberOfLines = 0;
        lab.font = [UIFont systemFontOfSize:13];
        lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        lab.layer.cornerRadius = 10;
        lab.layer.masksToBounds = YES;
        lab.textAlignment = NSTextAlignmentCenter;
        [lab sizeToFit];
        CGFloat pad = 14;
        lab.frame = CGRectMake(0, 0, lab.bounds.size.width + pad*2, lab.bounds.size.height + pad);
        lab.center = CGPointMake(vc.view.bounds.size.width/2, vc.view.bounds.size.height*0.15);
        lab.alpha = 0;
        [vc.view addSubview:lab];
        [UIView animateWithDuration:0.2 animations:^{ lab.alpha = 1; } completion:^(__unused BOOL f){
            [UIView animateWithDuration:0.25 delay:1.2 options:0 animations:^{ lab.alpha = 0; } completion:^(__unused BOOL f2){
                [lab removeFromSuperview];
            }];
        }];
    });
}

static void AS_EnsureOverlay(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            CGRect r = UIScreen.mainScreen.bounds;
            gAS_OverlayWindow = [[ASOverlayWindow alloc] initWithFrame:r];
            gAS_OverlayWindow.windowLevel = UIWindowLevelAlert + 2000;
            gAS_OverlayWindow.backgroundColor = UIColor.clearColor;

            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = UIColor.clearColor;
            vc.view.userInteractionEnabled = YES;
            gAS_OverlayWindow.rootViewController = vc;
            gAS_OverlayWindow.hidden = NO;
            // 不要抢占 keyWindow，否则微信可能点不动
            [UIApplication.sharedApplication.keyWindow makeKeyWindow];

            gAS_Button = [ASFloatButton buttonWithType:UIButtonTypeSystem];
            gAS_Button.frame = CGRectMake(r.size.width - 58, r.size.height * 0.35, 48, 48);
            gAS_Button.layer.cornerRadius = 24;
            gAS_Button.layer.masksToBounds = YES;
            gAS_Button.titleLabel.font = [UIFont boldSystemFontOfSize:12];

            [gAS_Button addTarget:nil action:@selector(as_btnTap) forControlEvents:UIControlEventTouchUpInside];

            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:nil action:@selector(as_btnLong)];
            [gAS_Button addGestureRecognizer:lp];

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(as_btnPan:)];
            [gAS_Button addGestureRecognizer:pan];

            [vc.view addSubview:gAS_Button];
            ((ASOverlayWindow *)gAS_OverlayWindow).as_touchView = gAS_Button;
            AS_SetEnabled(NO);
        });
    });
}

@interface NSObject (ASButtonActions)
- (void)as_btnTap;
- (void)as_btnLong;
- (void)as_btnPan:(UIPanGestureRecognizer *)g;
@end

static NSMutableArray<NSString *> *gAS_Captured = nil;

static void AS_PushCaptured(NSString *line) {
    if (!line.length) return;
    if (!gAS_Captured) gAS_Captured = [NSMutableArray array];
    NSString *last = gAS_Captured.lastObject;
    if ([last isEqualToString:line]) return;
    [gAS_Captured addObject:line];
    if (gAS_Captured.count > 200) [gAS_Captured removeObjectAtIndex:0];
}

@implementation NSObject (ASButtonActions)
- (void)as_btnTap {
    AS_SetEnabled(!gAS_Enabled);
    AS_ShowToast(gAS_Enabled ? @"AliSniffer：已启用" : @"AliSniffer：已关闭");
}
- (void)as_btnLong {
    if (!gAS_Captured.count) { AS_ShowToast(@"暂无抓取记录"); return; }
    NSMutableString *msg = [NSMutableString string];
    NSInteger start = MAX((NSInteger)gAS_Captured.count - 10, 0);
    for (NSInteger i = start; i < (NSInteger)gAS_Captured.count; i++) {
        [msg appendFormat:@"%ld) %@\n\n", (long)(i - start + 1), gAS_Captured[i]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = AS_TopVC();
        if (!vc) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"AliSniffer 抓取记录(最近10条)"
                                                                    message:msg
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"复制最新" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
            UIPasteboard.generalPasteboard.string = gAS_Captured.lastObject;
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){
            [gAS_Captured removeAllObjects];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:ac animated:YES completion:nil];
    });
}
- (void)as_btnPan:(UIPanGestureRecognizer *)g {
    if (!gAS_Button) return;
    CGPoint t = [g translationInView:gAS_Button.superview];
    gAS_Button.center = CGPointMake(gAS_Button.center.x + t.x, gAS_Button.center.y + t.y);
    [g setTranslation:CGPointMake(0,0) inView:gAS_Button.superview];
}
@end

static void AS_SetEnabled(BOOL en) {
    gAS_Enabled = en;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gAS_Button) return;
        gAS_Button.backgroundColor = en ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.85]
                                        : [[UIColor systemGrayColor] colorWithAlphaComponent:0.75];
        [gAS_Button setTitle:(en ? @"AS\nON" : @"AS\nOFF") forState:UIControlStateNormal];
        gAS_Button.titleLabel.numberOfLines = 2;
        gAS_Button.titleLabel.textAlignment = NSTextAlignmentCenter;
    });
}

static void AS_AutoEnableIfHost(NSString *host, NSString *reason) {
    if (!host.length) return;
    if (!AS_HostMatched(host)) return;
    if (gAS_Enabled || gAS_AutoEnabledByHost) return;
    gAS_AutoEnabledByHost = YES;
    AS_SetEnabled(YES);
    AS_ShowToast([NSString stringWithFormat:@"AliSniffer：已自动启用（%@）", reason ?: host]);
}

#pragma mark - Report

static void AS_ReportLine(NSString *line) {
    if (!line.length) return;
    NSLog(@"[AliSniffer] %@", line);
    AS_PushCaptured(line);
    @try {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AliSnifferFound"
                                                            object:nil
                                                          userInfo:@{@"line": line}];
    } @catch (...) {}
}

static NSString *AS_ShortBody(NSData *body) {
    if (!body.length) return nil;
    if (body.length > 8 * 1024) return [NSString stringWithFormat:@"<body %lu bytes>", (unsigned long)body.length];
    NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!s.length) return [NSString stringWithFormat:@"<body %lu bytes>", (unsigned long)body.length];
    return s;
}

static BOOL AS_ShouldCaptureRequest(NSURLRequest *r) {
    if (!gAS_Enabled) return NO;
    if (!r.URL) return NO;
    if (!AS_HostMatched(r.URL.host ?: @"")) return NO;
    NSString *u = r.URL.absoluteString ?: @"";
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

#pragma mark - NSURLSession hooks

static id (*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *);
static id swz_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    id task = orig_dataTaskWithRequest ? orig_dataTaskWithRequest(self, _cmd, request) : nil;
    if (request.URL.host.length) AS_AutoEnableIfHost(request.URL.host, @"NSURLSession");
    if (task && request) {
        @try { objc_setAssociatedObject(task, "as_req", request, OBJC_ASSOCIATION_RETAIN_NONATOMIC); } @catch(...) {}
    }
    return task;
}

static id (*orig_uploadTaskWithRequest_fromData)(id, SEL, NSURLRequest *, NSData *);
static id swz_uploadTaskWithRequest_fromData(id self, SEL _cmd, NSURLRequest *request, NSData *data) {
    id task = orig_uploadTaskWithRequest_fromData ? orig_uploadTaskWithRequest_fromData(self, _cmd, request, data) : nil;
    if (request.URL.host.length) AS_AutoEnableIfHost(request.URL.host, @"NSURLSession");
    if (task && request) {
        @try {
            objc_setAssociatedObject(task, "as_req", request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (data) objc_setAssociatedObject(task, "as_body", data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch(...) {}
    }
    return task;
}

static void (*orig_task_resume)(id, SEL);
static void swz_task_resume(id self, SEL _cmd) {
    @try {
        NSURLRequest *r = objc_getAssociatedObject(self, "as_req");
        if (!r && [self respondsToSelector:@selector(currentRequest)]) {
            @try { r = [self performSelector:@selector(currentRequest)]; } @catch(...) {}
        }
        if (r && AS_ShouldCaptureRequest(r)) {
            NSData *body = objc_getAssociatedObject(self, "as_body");
            NSString *method = r.HTTPMethod ?: @"GET";
            NSDictionary *h = r.allHTTPHeaderFields ?: @{};
            NSString *b = body ? AS_ShortBody(body) : AS_ShortBody(r.HTTPBody);

            NSString *line = b.length
                ? [NSString stringWithFormat:@"%@ %@\nHeaders:%@\nBody:%@", method, r.URL.absoluteString, h, b]
                : [NSString stringWithFormat:@"%@ %@\nHeaders:%@", method, r.URL.absoluteString, h];

            NSNumber *done = objc_getAssociatedObject(self, "as_reported");
            if (!done.boolValue) {
                AS_ReportLine(line);
                objc_setAssociatedObject(self, "as_reported", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    } @catch(...) {}
    if (orig_task_resume) orig_task_resume(self, _cmd);
}

__attribute__((constructor))
static void AS_InstallSessionHooks(void) {
    @autoreleasepool {
        AS_EnsureOverlay();

        Class S = NSClassFromString(@"NSURLSession");
        if (S) {
            AS_Swizzle(S, @selector(dataTaskWithRequest:), (IMP)swz_dataTaskWithRequest, (IMP *)&orig_dataTaskWithRequest);
            AS_Swizzle(S, @selector(uploadTaskWithRequest:fromData:),
                       (IMP)swz_uploadTaskWithRequest_fromData, (IMP *)&orig_uploadTaskWithRequest_fromData);
        }
        Class T = NSClassFromString(@"NSURLSessionTask");
        if (T) AS_Swizzle(T, @selector(resume), (IMP)swz_task_resume, (IMP *)&orig_task_resume);

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
                if (!gAS_Enabled) return;
                AVPlayerItemAccessLog *log = item.accessLog;
                id ev = log.events.lastObject;
                NSString *uri = nil;
                if ([ev respondsToSelector:NSSelectorFromString(@"URI")]) uri = [ev valueForKey:@"URI"];
                if (uri.length) AS_ReportLine([NSString stringWithFormat:@"AVAccessLog URI: %@", uri]);
            } @catch(...) {}
        }];
    } @catch(...) {}
}

static id (*orig_item_initWithURL)(id, SEL, NSURL *);
static id swz_item_initWithURL(id self, SEL _cmd, NSURL *URL) {
    if (URL.host.length) AS_AutoEnableIfHost(URL.host, @"AVPlayerItem");
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

#pragma mark - WKWebView inject (auto-enable + resource sniff)

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
        AS_ReportLine([NSString stringWithFormat:@"WK(%@): %@", type ?: @"?", url]);
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
      "if(matchHost()) { post('host', location.href); }"
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
        if (req.URL.host.length) AS_AutoEnableIfHost(req.URL.host, @"WKWebView");
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
