import Darwin
import Foundation
import LipiEditor
import LipiFixtures
import LipiLayout

/// Command line shared by the SwiftPM executable and the app bundle:
/// `BareLipi [--fixture <name> | <path>] [--engine lipi|textkit2]
/// [--theme paper|snow|ink|slate] [--zoom <factor>] [--measure <seconds>]`.
/// Arguments the system passes to a bundle (`-psn_…`, `-NSDocumentRevisionsDebugMode YES`
/// and other `-Key value` defaults) are skipped when `lenient` is set.
public struct LaunchOptions {
    public var fixture: PerfFixture? = nil
    public var path: String? = nil
    public var engine: LayoutEngineKind = .lipi
    public var theme: Theme = .paper
    public var zoom: CGFloat = 1
    public var measureSeconds: Double? = nil

    public init() {}

    public static func parse(_ arguments: [String], lenient: Bool = false) -> LaunchOptions {
        var options = LaunchOptions()
        var i = 1
        func value() -> String? { i + 1 < arguments.count ? arguments[i + 1] : nil }
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--fixture":
                guard let name = value(), let fixture = PerfFixture(rawValue: name) else {
                    fail("--fixture needs one of: \(PerfFixture.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                options.fixture = fixture; i += 1
            case "--engine":
                guard let name = value(), let engine = LayoutEngineKind(rawValue: name) else { fail("--engine lipi|textkit2") }
                options.engine = engine; i += 1
            case "--theme":
                guard let name = value(), let theme = Theme.all.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                    fail("--theme needs one of: \(Theme.all.map { $0.name.lowercased() }.joined(separator: ", "))")
                }
                options.theme = theme; i += 1
            case "--zoom":
                guard let v = value(), let zoom = Double(v) else { fail("--zoom <factor>") }
                options.zoom = CGFloat(zoom); i += 1
            case "--measure":
                guard let v = value(), let seconds = Double(v) else { fail("--measure <seconds>") }
                options.measureSeconds = seconds; i += 1
            case "--help", "-h":
                print("usage: BareLipi [--fixture <name> | <path>] [--engine lipi|textkit2] [--theme paper|snow|ink|slate] [--zoom <factor>] [--measure <seconds>]")
                exit(0)
            default:
                if lenient, arg.hasPrefix("-psn_") { break }
                if lenient, arg.hasPrefix("-"), !arg.hasPrefix("--") { i += 1; break }  // -Key value (NSUserDefaults)
                if arg.hasPrefix("-") { fail("unknown option \(arg)") }
                options.path = arg
            }
            i += 1
        }
        return options
    }

    public static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(64)
    }

    /// The document to open: fixture, file, or the welcome text.
    public func text() throws -> String {
        if let fixture { return fixture.text() }
        if let path { return try String(contentsOfFile: path, encoding: .utf8) }
        return LaunchOptions.welcome
    }

    public var title: String {
        if let fixture { return "BareLipi — \(fixture.rawValue)" }
        if let path { return "BareLipi — \((path as NSString).lastPathComponent)" }
        return "BareLipi"
    }

    public static let welcome = """
    # BareLipi

    ಬರೆ · ಲಿಪಿ — a native Markdown editor. Type here; syntax reveals itself around the caret.

    Kannada shapes correctly: ಕ್ಷೇತ್ರ ಮತ್ತು ಜ್ಞಾನ. Devanagari too: ज्ञान और क्षेत्र. Emphasis is *revealed* when you enter it, **strong** likewise, and `code` keeps its pill. A [link](https://example.com) folds to a chip.

    > Quotes hang their bar in the gutter.

    - Lists keep their markers in the gutter
    - [ ] tasks included

    | Column | Value |
    | --- | ---: |
    | alpha | 1 |
    | beta | 22 |

    ```swift
    let x = 1
    ```

    """
}

/// Wall-clock start of this process from the kernel (for the pre-main figure).
public func processStartTime() -> Date? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
}

public func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let rank = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
    return sorted[rank]
}

public func ms(_ seconds: Double) -> String { String(format: "%.2f ms", seconds * 1000) }
