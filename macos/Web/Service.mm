#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_parser.h"
#include "include/wrapper/cef_library_loader.h"
#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <array>
#include <chrono>
#include <cmath>
#include <limits>
#include <mutex>
#include <xpc/xpc.h>

@interface VividWebApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation VividWebApplication
- (BOOL)isHandlingSendEvent {
    return self.handlingSendEvent;
}
- (void)sendEvent:(NSEvent*)event {
    CefScopedSendingEvent sending;
    [super sendEvent:event];
}
@end

namespace {
std::string string(xpc_object_t message, const char* key) {
    const char* value = xpc_dictionary_get_string(message, key);
    return value ? value : "";
}
class BrowserSession final : public CefClient,
                             public CefRenderHandler,
                             public CefLifeSpanHandler,
                             public CefLoadHandler,
                             public CefRequestHandler {
  public:
    explicit BrowserSession(xpc_connection_t peer) : peer_(peer) {
        settings_->SetInt("fps", 30);
        settings_->SetDouble("volume", 1.0);
        settings_->SetBool("muted", false);
        settings_->SetDictionary("properties", CefDictionaryValue::Create());
    }
    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override { rect = CefRect(0, 0, width_, height_); }
    void OnPaint(CefRefPtr<CefBrowser>, PaintElementType, const RectList&, const void*, int, int) override {
        fail("CEF did not provide an accelerated IOSurface.");
    }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { browser_ = browser; }
    void OnBeforeClose(CefRefPtr<CefBrowser>) override { browser_ = nullptr; }
    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString&, const CefString&,
                       WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&,
                       CefRefPtr<CefClient>&, CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&,
                       bool*) override {
        return true;
    }
    void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int) override {
        if (frame->IsMain()) {
            loaded_ = true;
            apply();
        }
    }
    void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString& text,
                     const CefString&) override {
        if (frame->IsMain() && code != ERR_ABORTED)
            fail(text.ToString());
    }
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus, int,
                                   const CefString& text) override {
        fail("Chromium renderer stopped: " + text.ToString());
    }

    void receive(xpc_object_t message) {
        if (stopped_)
            return;
        if (xpc_dictionary_get_uint64(message, "version") != 1) {
            fail("Web protocol mismatch");
            return;
        }
        const auto op = string(message, "operation");
        if (op == "start")
            start(message);
        else if (op == "configure") {
            readSettings(message);
            apply();
        } else if (op == "release") {
            auto slot = xpc_dictionary_get_uint64(message, "slot");
            auto sequence = xpc_dictionary_get_uint64(message, "sequence");
            if (xpc_dictionary_get_uint64(message, "generation") == 1 && slot < slots_.size() &&
                slots_[slot].sequence == sequence)
                slots_[slot].leased = false;
        } else if (op == "pause" && browser_) {
            paused_ = xpc_dictionary_get_bool(message, "paused");
            apply();
            browser_->GetHost()->WasHidden(paused_);
        } else if (op == "pointer" && browser_ && !paused_) {
            const auto x = xpc_dictionary_get_double(message, "x"),
                       y = xpc_dictionary_get_double(message, "y");
            if (!std::isfinite(x) || !std::isfinite(y))
                return;
            const bool down = xpc_dictionary_get_bool(message, "left");
            CefMouseEvent event;
            event.x = std::clamp(x, 0.0, 1.0) * (width_ - 1);
            event.y = std::clamp(y, 0.0, 1.0) * (height_ - 1);
            event.modifiers = down ? EVENTFLAG_LEFT_MOUSE_BUTTON : 0;
            browser_->GetHost()->SendMouseMoveEvent(event, false);
            if (down != left_)
                browser_->GetHost()->SendMouseClickEvent(event, MBT_LEFT, !down, 1);
            left_ = down;
        } else if (op == "stop")
            stop();
    }

    void stop() {
        if (stopped_)
            return;
        stopped_ = true;
        if (browser_)
            browser_->GetHost()->CloseBrowser(true);
        request_ = nil;
    }

    void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
                            const CefAcceleratedPaintInfo& info) override {
        if (stopped_ || paused_ || type != PET_VIEW)
            return;
        size_t slot = 0;
        for (; slot < slots_.size() && slots_[slot].leased; ++slot) {
        }
        if (slot == slots_.size())
            return;
        if (info.format != CEF_COLOR_TYPE_BGRA_8888) {
            fail("Unsupported CEF surface color format");
            return;
        }
        IOSurfaceRef surface = static_cast<IOSurfaceRef>(info.shared_texture_io_surface);
        if (!surface || IOSurfaceGetWidth(surface) != static_cast<size_t>(width_) ||
            IOSurfaceGetHeight(surface) != static_cast<size_t>(height_))
            return;
        MTLTextureDescriptor* desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width_
                                                              height:height_
                                                           mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> source = [device_ newTextureWithDescriptor:desc iosurface:surface plane:0];
        id<MTLCommandBuffer> command = [commands_ commandBuffer];
        id<MTLBlitCommandEncoder> copy = [command blitCommandEncoder];
        if (!source || !command || !copy) {
            fail("Cannot copy CEF IOSurface");
            return;
        }
        [copy copyFromTexture:source
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(width_, height_, 1)
                    toTexture:slots_[slot].texture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [copy endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.error) {
            fail(command.error.localizedDescription.UTF8String);
            return;
        }
        slots_[slot].leased = true;
        slots_[slot].sequence = ++sequence_;
        auto frame = event("frame");
        xpc_dictionary_set_uint64(frame, "slot", slot);
        xpc_dictionary_set_uint64(frame, "sequence", sequence_);
        xpc_connection_send_message(peer_, frame);
    }

  private:
    struct Slot {
        id<MTLTexture> texture;
        bool leased = false;
        uint64_t sequence = 0;
    };
    xpc_connection_t peer_;
    xpc_object_t request_ = nil;
    CefRefPtr<CefBrowser> browser_;
    id<MTLDevice> device_;
    id<MTLCommandQueue> commands_;
    std::array<Slot, 3> slots_;
    CefRefPtr<CefDictionaryValue> settings_ = CefDictionaryValue::Create();
    int width_ = 1, height_ = 1;
    uint64_t sequence_ = 0;
    bool stopped_ = false, paused_ = false, left_ = false, loaded_ = false;

    xpc_object_t event(const char* operation) {
        auto message = xpc_dictionary_create(nullptr, nullptr, 0);
        xpc_dictionary_set_uint64(message, "version", 1);
        xpc_dictionary_set_uint64(message, "generation", 1);
        xpc_dictionary_set_string(message, "operation", operation);
        return message;
    }
    void fail(const std::string& reason) {
        if (stopped_)
            return;
        auto message = event("failed");
        xpc_dictionary_set_string(message, "reason", reason.c_str());
        xpc_connection_send_message(peer_, message);
        stop();
    }
    void readSettings(xpc_object_t message) {
        size_t size = 0;
        const auto* bytes = static_cast<const char*>(xpc_dictionary_get_data(message, "settings", &size));
        if (!bytes)
            return;
        auto value = CefParseJSON(bytes, size, JSON_PARSER_RFC);
        if (!value || value->GetType() != VTYPE_DICTIONARY) {
            fail("Invalid web settings");
            return;
        }
        auto next = value->GetDictionary();
        const int fps = next->GetInt("fps");
        const double volume =
            next->GetType("volume") == VTYPE_INT ? next->GetInt("volume") : next->GetDouble("volume");
        if (fps < 5 || fps > 240 || !std::isfinite(volume) || volume < 0 || volume > 1 ||
            next->GetType("properties") != VTYPE_DICTIONARY) {
            fail("Invalid web playback settings");
            return;
        }
        next->SetDouble("volume", volume);
        settings_ = next;
    }
    void apply() {
        if (!browser_ || stopped_)
            return;
        const bool muted = settings_->GetBool("muted");
        browser_->GetHost()->SetAudioMuted(muted);
        browser_->GetHost()->SetWindowlessFrameRate(std::clamp(settings_->GetInt("fps"), 5, 60));
        if (!loaded_)
            return;
        auto properties = settings_->GetDictionary("properties");
        auto wrapped = CefDictionaryValue::Create();
        if (properties) {
            CefDictionaryValue::KeyList keys;
            properties->GetKeys(keys);
            for (const auto& key : keys) {
                auto property = CefDictionaryValue::Create();
                property->SetValue("value", properties->GetValue(key));
                wrapped->SetDictionary(key, property);
            }
        }
        auto value = CefValue::Create();
        value->SetDictionary(wrapped);
        const auto json = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
        const auto volume = settings_->GetDouble("volume");
        const auto script =
            "window.__vividApplyUserProperties(" + json +
            ");window.__vividApplyGeneralProperties({fps:" + std::to_string(settings_->GetInt("fps")) +
            ",volume:" + std::to_string(volume * 100) + "});window.__vividSetPaused(" +
            (paused_ ? "true" : "false") +
            ");document.querySelectorAll('video,audio').forEach(function(e){e.volume=" +
            std::to_string(volume) + ";});";
        browser_->GetMainFrame()->ExecuteJavaScript(script, "vivid://settings", 0);
    }
    void start(xpc_object_t message) {
        if (request_) {
            fail("Web session already started");
            return;
        }
        request_ = message;
        width_ = static_cast<int>(xpc_dictionary_get_uint64(message, "width"));
        height_ = static_cast<int>(xpc_dictionary_get_uint64(message, "height"));
        if (width_ < 1 || height_ < 1 || width_ > 8192 || height_ > 8192) {
            fail("Invalid web dimensions");
            return;
        }
        const auto path = string(message, "project");
        NSURL* root = [NSURL fileURLWithPath:@(path.c_str()) isDirectory:YES];
        NSData* data = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"project.json"]];
        NSDictionary* manifest =
            data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString* file = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"file"] : nil;
        if (![file isKindOfClass:NSString.class])
            file = @"index.html";
        NSURL* entry = [[root URLByAppendingPathComponent:file] URLByResolvingSymlinksInPath];
        if (![entry.path hasPrefix:[root.path stringByAppendingString:@"/"]] ||
            ![[NSFileManager defaultManager] fileExistsAtPath:entry.path]) {
            fail("Web entry is missing or outside the project");
            return;
        }
        readSettings(message);
        if (stopped_)
            return;
        device_ = MTLCreateSystemDefaultDevice();
        commands_ = [device_ newCommandQueue];
        auto pool = event("pool");
        auto surfaces = xpc_array_create(nullptr, 0);
        for (auto& slot : slots_) {
            NSDictionary* properties = @{
                @"IOSurfaceWidth" : @(width_),
                @"IOSurfaceHeight" : @(height_),
                @"IOSurfaceBytesPerElement" : @4,
                @"IOSurfacePixelFormat" : @(kCVPixelFormatType_32BGRA)
            };
            IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
            auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                           width:width_
                                                                          height:height_
                                                                       mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            desc.usage = MTLTextureUsageShaderRead;
            slot.texture = [device_ newTextureWithDescriptor:desc iosurface:surface plane:0];
            if (!surface || !slot.texture) {
                if (surface)
                    CFRelease(surface);
                fail("Cannot allocate web frame pool");
                return;
            }
            xpc_array_append_value(surfaces, IOSurfaceCreateXPCObject(surface));
            CFRelease(surface);
        }
        xpc_dictionary_set_value(pool, "surfaces", surfaces);
        xpc_connection_send_message(peer_, pool);
        CefWindowInfo info;
        info.SetAsWindowless(nullptr);
        info.shared_texture_enabled = true;
        CefBrowserSettings settings;
        settings.windowless_frame_rate = 30;
        settings.background_color = CefColorSetARGB(255, 0, 0, 0);
        browser_ = CefBrowserHost::CreateBrowserSync(info, this, entry.absoluteString.UTF8String, settings,
                                                     nullptr, nullptr);
        if (!browser_)
            fail("Cannot create Chromium wallpaper browser");
    }
    IMPLEMENT_REFCOUNTING(BrowserSession);
};
class Pump final : public CefApp, public CefBrowserProcessHandler {
  public:
    Pump() {
        timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(timer_, ^{
          {
              std::lock_guard lock(mutex_);
              deadline_ = std::numeric_limits<int64_t>::max();
          }
          CefDoMessageLoopWork();
        });
        dispatch_resume(timer_);
    }
    ~Pump() override { dispatch_source_cancel(timer_); }
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
    void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
        command->AppendSwitchWithValue("autoplay-policy", "no-user-gesture-required");
        command->AppendSwitch("allow-file-access-from-files");
    }
    void OnScheduleMessagePumpWork(int64_t delay) override {
        // One outstanding timer, always retaining the earliest requested work.
        const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now().time_since_epoch())
                             .count();
        const auto bounded = std::clamp<int64_t>(delay, 0, 60000);
        std::lock_guard lock(mutex_);
        if (now + bounded >= deadline_)
            return;
        deadline_ = now + bounded;
        dispatch_source_set_timer(timer_, dispatch_time(DISPATCH_TIME_NOW, bounded * NSEC_PER_MSEC),
                                  DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
    }

  private:
    dispatch_source_t timer_;
    std::mutex mutex_;
    int64_t deadline_ = std::numeric_limits<int64_t>::max();
    IMPLEMENT_REFCOUNTING(Pump);
};
} // namespace

int main(int argc, char* argv[]) {
    @autoreleasepool {
        [VividWebApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CefScopedLibraryLoader loader;
        if (!loader.LoadInMain())
            return 1;
        CefSettings settings;
        settings.no_sandbox = true;
        settings.windowless_rendering_enabled = true;
        settings.external_message_pump = true;
        NSString* bundle = NSBundle.mainBundle.bundlePath;
        NSString* helper =
            [bundle stringByAppendingPathComponent:
                        @"Contents/Frameworks/VividWeb Helper.app/Contents/MacOS/VividWeb Helper"];
        CefString(&settings.browser_subprocess_path) = helper.UTF8String;
        // Chromium uses the outer .app to determine whether it is bundled.
        // An XPC bundle is not an .app, even though it owns the CEF framework.
        NSString* outerBundle = [[[bundle stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        CefString(&settings.main_bundle_path) = outerBundle.UTF8String;
        NSString* framework = [bundle
            stringByAppendingPathComponent:@"Contents/Frameworks/Chromium Embedded Framework.framework"];
        CefString(&settings.framework_dir_path) = framework.UTF8String;
        CefString(&settings.resources_dir_path) =
            [framework stringByAppendingPathComponent:@"Resources"].UTF8String;
        NSString* cache = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[@"vivid-cef-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        CefString(&settings.root_cache_path) = cache.UTF8String;
        if (!CefInitialize(CefMainArgs(argc, argv), settings, new Pump, nullptr))
            return 1;
        xpc_main([](xpc_connection_t peer) {
            CefRefPtr<BrowserSession> session = new BrowserSession(peer);
            xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
            xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
              @autoreleasepool {
                  if (xpc_get_type(message) == XPC_TYPE_DICTIONARY)
                      session->receive(message);
                  else {
                      session->stop();
                      xpc_connection_cancel(peer);
                      xpc_connection_set_event_handler(peer, ^(xpc_object_t){
                                                       });
                  }
              }
            });
            xpc_connection_resume(peer);
        });
    }
}
