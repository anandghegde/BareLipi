import AppKit
import WebKit

/// Paginates an HTML page with WebKit for Print and PDF export (P0-14,
/// Phase 2). The page is loaded into an offscreen `WKWebView` (hosted in a
/// window that is never shown; WebKit lays out and draws in its own
/// process, so the main thread only coordinates), and WebKit's print
/// operation breaks it into pages: text stays text, code keeps its token
/// colours, images and MathML render, and `@page` sets the margins.
///
/// One renderer is one page; keep it alive until its operation finishes.
@MainActor
public final class WebPDFRenderer: NSObject {
    public enum Failure: LocalizedError {
        case loadFailed(String)
        case webProcessEnded
        case printFailed

        public var errorDescription: String? {
            switch self {
            case .loadFailed(let why): return "The page could not be laid out for printing (\(why))."
            case .webProcessEnded: return "The page could not be laid out for printing (WebKit stopped)."
            case .printFailed: return "The pages could not be produced."
            }
        }
    }

    public let webView: WKWebView
    private let window: NSWindow
    private var loaded: CheckedContinuation<Void, Error>?
    private var finished: CheckedContinuation<Bool, Never>?

    /// `width` is the layout width before pagination; the print operation
    /// re-lays the page out at the paper's width.
    public init(width: CGFloat = 612) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 792)
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: frame, configuration: configuration)
        // Paper is light: a page with `prefers-color-scheme: dark` rules
        // must not pick them up from a dark system appearance.
        webView.appearance = NSAppearance(named: .aqua)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads `html` and waits for it, images included. `baseURL` resolves
    /// relative links (images are expected embedded).
    public func load(html: String, baseURL: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// A print operation over the loaded page, with `printInfo`'s paper,
    /// orientation and scaling (the margins come from the page's `@page`).
    public func printOperation(printInfo: NSPrintInfo, title: String) -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.view?.frame = webView.bounds
        return operation
    }

    /// Runs `operation` without blocking: as a sheet on `window` when it
    /// shows its panel, else detached (the renderer's own window hosts it).
    /// Returns whether it ran to completion (false when cancelled).
    public func run(_ operation: NSPrintOperation, sheetOn window: NSWindow? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            finished = continuation
            operation.runModal(for: window ?? self.window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    /// Paginates the loaded page into a PDF on `printInfo`'s paper.
    public func pdfData(printInfo: NSPrintInfo, title: String) async throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BareLipi-print-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("page.pdf")
        let info = printInfo.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = printOperation(printInfo: info, title: title)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard await run(operation), let data = try? Data(contentsOf: url), !data.isEmpty else { throw Failure.printFailed }
        return data
    }

    /// AppKit calls this on the thread that ran the operation, which is not
    /// the main thread when no panel was shown.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.finished?.resume(returning: success)
                self.finished = nil
            }
        }
    }

    private func finishLoad(_ error: Error?) {
        guard let loaded else { return }
        self.loaded = nil
        if let error { loaded.resume(throwing: error) } else { loaded.resume() }
    }
}

extension WebPDFRenderer: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(nil) }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(Failure.loadFailed(error.localizedDescription))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(Failure.loadFailed(error.localizedDescription))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishLoad(Failure.webProcessEnded) }

    /// Links in the page are not followed: it is only laid out.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}
