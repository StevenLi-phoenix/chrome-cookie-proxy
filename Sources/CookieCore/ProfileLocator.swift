import Foundation

struct SelectedProfile: Equatable {
    var name: String
    var cookiesFile: URL
}

/// 选 Chrome profile。自动模式在 `Default` 和 `Profile *` 里取 Cookies 文件修改时间最新的，
/// 和 yt-dlp 一致。新版 Chrome 把库放在 `<profile>/Network/Cookies`，旧版是 `<profile>/Cookies`，两个都认。
enum ProfileLocator {
    static let cookieRelativePaths = ["Network/Cookies", "Cookies"]

    static func select(chromeRoot: URL, profile: String?) throws -> SelectedProfile {
        let fm = FileManager.default
        let names: [String]
        if let profile {
            guard !profile.isEmpty, !profile.contains("/"), profile != ".", profile != ".." else { throw ExportError.noProfile }
            names = [profile]
        } else {
            let entries = (try? fm.contentsOfDirectory(atPath: chromeRoot.path)) ?? []
            names = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        }

        var best: (profile: SelectedProfile, mtime: Date)?
        for name in names {
            let dir = chromeRoot.appendingPathComponent(name, isDirectory: true)
            for rel in cookieRelativePaths {
                let file = dir.appendingPathComponent(rel)
                guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                      attrs[.type] as? FileAttributeType == .typeRegular,
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if best == nil || mtime > best!.mtime {
                    best = (SelectedProfile(name: name, cookiesFile: file), mtime)
                }
            }
        }
        guard let best else { throw ExportError.noProfile }
        return best.profile
    }
}
