import AppKit

/// Shows Tiller's windows and tabs to extensions' tabs and windows APIs, which
/// only see Chrome's own windows otherwise, so `chrome.tabs.query` found no
/// tabs and popups that ask for the current tab, such as 1Password's, stayed
/// blank. Tiller's CEF build asks for them each time an extension does; a
/// framework without that patch leaves the APIs as they were.
///
/// Each profile in a window counts as a window of its own, so an extension
/// sees only its profile's tabs.
@MainActor
enum ExtensionWindows {
    private typealias Provider = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetProvider = @convention(c) (UnsafeMutableRawPointer?, Provider?) -> Void
    private typealias AddWindow = @convention(c) (
        Int32, Bool, Int32, Int32, Int32, Int32, UnsafePointer<Int32>?, Int32, Int32
    ) -> Void

    private static var addWindow: AddWindow?
    private static var nextKey: Int32 = 0

    /// Call once CEF is loaded.
    static func install() {
        guard let path = Bundle.main.privateFrameworksPath,
              let handle = dlopen(path + "/Chromium Embedded Framework.framework/Chromium Embedded Framework", RTLD_LAZY | RTLD_NOLOAD),
              let set = dlsym(handle, "tiller_ext_set_window_provider"),
              let add = dlsym(handle, "tiller_ext_add_window")
        else { return }
        addWindow = unsafeBitCast(add, to: AddWindow.self)
        unsafeBitCast(set, to: SetProvider.self)(nil) { _ in
            MainActor.assumeIsolated { ExtensionWindows.report() }
        }
    }

    /// A new key for a browser window controller to be known by.
    static func makeKey() -> Int32 {
        nextKey += 1
        return nextKey
    }

    /// Reports every profile's window, the most recently active first: windows
    /// front to back, and in each the profile shown before the others.
    private static func report() {
        guard let addWindow else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let hosts = NSApp.orderedWindows.compactMap { window in
            BrowserWindowHost.all.first { $0.window === window }
        }
        for (position, host) in hosts.enumerated() {
            guard let window = host.window else { continue }
            let frame = window.frame
            let browsers = host.browsers.filter { $0 === host.shown } + host.browsers.filter { $0 !== host.shown }
            for browser in browsers {
                let (ids, active) = browser.extensionTabs
                guard !ids.isEmpty else { continue }
                let focused = NSApp.isActive && position == 0 && browser === host.shown
                ids.withUnsafeBufferPointer { buffer in
                    addWindow(
                        browser.extensionWindowKey, focused,
                        Int32(frame.minX), Int32(primaryHeight - frame.maxY),
                        Int32(frame.width), Int32(frame.height),
                        buffer.baseAddress, Int32(buffer.count), active
                    )
                }
            }
        }
    }
}
