import Foundation

/// A fresh directory under the system temp directory, removed by `cleanUp`.
struct TempDirectory {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // realpath: /var -> /private/var, so paths compare equal to resolved ones.
        let resolved = URL(fileURLWithPath: base.resolvingSymlinksInPath().path, isDirectory: true)
        let made = resolved.appendingPathComponent("LipiAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: realpath(made.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? made.path)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func cleanUp() {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }
}

func bytes(_ string: String) -> Data { Data(string.utf8) }
