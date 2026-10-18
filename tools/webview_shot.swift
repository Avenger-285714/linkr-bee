#!/usr/bin/env swift
// Snapshot a page in an offscreen WKWebView at an exact CSS viewport.
//
// This exists because headless Chrome is unreliable in this sandbox and, more
// importantly, because Chrome is not the renderer the app actually ships with:
// Android uses Chrome, but iOS and HarmonyOS both run WebKit-derived engines.
// Taking the shot with WKWebView means the width, the font metrics and the
// safe-area behaviour match iOS more closely than a Chrome capture would.
//
//   swift tools/webview_shot.swift <url> <out.png> <width> <height> <dark|light> [panel]
//
// LIMITATION: this WebView is driven by a run loop, not by the compositor, so
// style changes made after load are not necessarily repainted. Inline styles,
// data-theme toggles and class changes can all leave existing elements showing
// their first computed values, while freshly created elements report the new
// ones. Snapshot therefore reliably captures the FIRST frame only.
// To review a theme, make it the first frame (e.g. set data-theme in the HTML
// before loading) rather than switching it from JavaScript.
//
// Example:
//   swift tools/webview_shot.swift http://127.0.0.1:8778/index.html \
//     /tmp/phone.png 390 844 dark closed

import Cocoa
import WebKit

let args = CommandLine.arguments
guard args.count >= 6 else {
    FileHandle.standardError.write("usage: webview_shot <url> <out.png> <w> <h> <dark|light> [panel]\n".data(using: .utf8)!)
    exit(1)
}
let urlString = args[1]
let outPath = args[2]
let width = CGFloat(Double(args[3]) ?? 390)
let height = CGFloat(Double(args[4]) ?? 844)
let theme = args[5]
let panel = args.count > 6 ? args[6] : "closed"

guard let url = URL(string: urlString) else {
    FileHandle.standardError.write("bad url\n".data(using: .utf8)!)
    exit(1)
}

// WKWebView keeps a process-wide HTTP cache; a non-persistent data store does
// not touch it, so sub-resources (the stylesheet) kept coming back stale.
URLCache.shared.removeAllCachedResponses()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Shooter: NSObject, WKNavigationDelegate {
    var web: WKWebView!
    // An offscreen WKWebView never enters the render loop: existing elements keep
    // their first computed style, inline style changes are ignored and the
    // snapshot returns the first frame. Parking it in a real (borderless) window
    // is what makes later DOM mutations actually paint.
    var window: NSWindow!
    let outPath: String
    // Stored as properties: a bare `panel` inside a method resolves to AppKit's
    // global and fails to compile, and init parameters are out of scope there.
    let themeName: String
    let panelState: String

    init(url: URL, width: CGFloat, height: CGFloat, outPath: String, theme: String, panel: String) {
        self.outPath = outPath
        self.themeName = theme
        self.panelState = panel
        super.init()
        let config = WKWebViewConfiguration()
        // A persistent store kept serving the previous stylesheet, which made
        // every iteration after the first review the build before it.
        config.websiteDataStore = .nonPersistent()
        let seed = """
        try { localStorage.setItem('linkr-theme','\(theme)');
              localStorage.setItem('linkr-sidebar','\(panel)'); } catch (e) {}
        """
        config.userContentController.addUserScript(
            WKUserScript(source: seed, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.backgroundColor = .black
        window.orderFrontRegardless()
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                               timeoutInterval: 20)
        web.load(request)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WKWebView caches sub-resources far harder than the top document, and
        // neither a non-persistent store nor URLCache eviction defeated it. Re-request
        // every stylesheet with a fresh query so the capture always reflects disk.
        webView.evaluateJavaScript("""
        document.querySelectorAll('link[rel=stylesheet]').forEach(function (l) {
          l.href = l.href.split('?')[0] + '?cb=' + Date.now();
        });
        """) { _, _ in }
        // The localStorage seed runs at document start, before the origin is
        // established, so it silently no-ops. Force the state on the DOM just
        // before the shot instead, after app.js has finished its own pass.
        webView.evaluateJavaScript(
            "document.documentElement.setAttribute('data-theme','\(themeName)');"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            let openDrawer = (self.panelState == "open") ? "true" : "false"
            webView.evaluateJavaScript(
                "document.documentElement.setAttribute('data-theme','\(self.themeName)');"
                + "if (\(openDrawer)) document.querySelector('#panelToggle')?.click();"
            ) { _, error in
                if let error { print("set failed: \(error)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) {
            let snapshot = WKSnapshotConfiguration()
            // Offscreen WKWebView does not repaint on its own: without this the
            // capture returns the frame from before the theme attribute changed.
            snapshot.afterScreenUpdates = true
            snapshot.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: webView.bounds.height)
            webView.takeSnapshot(with: snapshot) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                    exit(2)
                }
                try? png.write(to: URL(fileURLWithPath: self.outPath))
                print("\(self.outPath)  \(Int(image.size.width))x\(Int(image.size.height))")
                exit(0)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("navigation failed: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(3)
    }
}

let shooter = Shooter(url: url, width: width, height: height, outPath: outPath, theme: theme, panel: panel)
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    FileHandle.standardError.write("timed out\n".data(using: .utf8)!)
    exit(4)
}
withExtendedLifetime(shooter) { app.run() }
