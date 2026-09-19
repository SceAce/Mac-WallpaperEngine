#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/wrapper/cef_library_loader.h"
#include "vivid_web_bridge_js.h"

class WebApp final : public CefApp, public CefRenderProcessHandler {
  public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        frame->ExecuteJavaScript(kVividWebBridgeJs, "vivid://bridge", 0);
    }

  private:
    IMPLEMENT_REFCOUNTING(WebApp);
};

int main(int argc, char* argv[]) {
    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper())
        return 1;
    return CefExecuteProcess(CefMainArgs(argc, argv), new WebApp, nullptr);
}
