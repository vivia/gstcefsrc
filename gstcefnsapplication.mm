#include "gstcefsrc.h"

#include <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CFRunLoop.h>
#import <Appkit/AppKit.h>
#include <include/base/cef_lock.h>
#include <include/cef_app.h>
#include <include/cef_application_mac.h>
#include <objc/runtime.h>
#include <syslog.h>

#include <set>

namespace {
bool g_handling_send_event = false;
} // namespace

@interface NSApplication (GstCEFApplication) <CefAppProtocol>

- (BOOL)isHandlingSendEvent;
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
- (void)_swizzled_sendEvent:(NSEvent *)event;
- (void)_swizzled_terminate:(id)sender;

@end

@implementation NSApplication (GstCEFApplication)

- (void)_swizzled_run {
  syslog(LOG_NOTICE, "Starting CEF-inoculated app...");
  [self _swizzled_run];
}

// This selector is called very early during the application initialization.
+ (void)load {
  if ([NSThread currentThread] != [NSThread mainThread]) {
    syslog(LOG_ERR, "Swizzling from outside the main thread, relocating...");
    [NSApplication performSelectorOnMainThread:@selector(load) withObject:self waitUntilDone:false];
    return;
  }
  syslog(LOG_NOTICE, "Swizzling NSApplication for use with CEF...");

  auto swizzle = [&](auto src, auto dst) {
    Method originalTerm = class_getInstanceMethod(self, src);
    Method swizzledTerm =
        class_getInstanceMethod(self, dst);
    assert (originalTerm != nullptr && swizzledTerm != nullptr);
    method_exchangeImplementations(originalTerm, swizzledTerm);
  };

  swizzle(@selector(terminate:), @selector(_swizzled_terminate:));
  swizzle(@selector(sendEvent:), @selector(_swizzled_sendEvent:));
  swizzle(@selector(run), @selector(_swizzled_run));
  syslog(LOG_NOTICE, "Swizzling complete.");
}

- (BOOL)isHandlingSendEvent {
  syslog(LOG_DEBUG, "Is handling [NSEvent sendEvent]: %i",
         g_handling_send_event);
  return g_handling_send_event;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  syslog(LOG_DEBUG, "Set handling [NSEvent sendEvent]: %i", handlingSendEvent);
  g_handling_send_event = handlingSendEvent;
}

- (void)_swizzled_sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  syslog(LOG_DEBUG, "[NSEvent sendEvent]: %p", event);
  // Calls NSApplication::sendEvent due to the swizzling.
  [self _swizzled_sendEvent:event];
}

// This method will be called via Cmd+Q.
- (void)_swizzled_terminate:(id)sender {
  CefShutdown();
  [self _swizzled_terminate:sender];
}
@end

typedef struct _GstCefSrc GstCefSrc;

CFRunLoopTimerRef install_loop(GstCefSrc *src)
{
  GST_WARNING_OBJECT (src, "Installing event handler on main thread");
  return (CFRunLoopTimerRef)[NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
    CefDoMessageLoopWork();
  }];
}
