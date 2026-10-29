import Foundation

/// Display-only formatting. Nothing here influences how files are dated or placed;
/// the parent model owns every value that is shown.
enum UIFormat {
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func speed(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }
        return formattedBytes(Int64(bytesPerSecond)) + "/秒"
    }

    /// Remaining time only when it can be estimated from real throughput.
    static func remaining(_ progress: ImportProgress) -> String? {
        guard progress.bytesPerSecond > 0, progress.totalBytes > progress.bytesCopied else { return nil }
        let seconds = Double(progress.totalBytes - progress.bytesCopied) / progress.bytesPerSecond
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        f.calendar = calendar
        return f.string(from: seconds).map { "残り約\($0)" }
    }

    /// Capture date rendered in the shooting time zone chosen by the user, never the Mac's zone.
    static func captureDate(_ date: Date?, zoneID: String) -> String {
        guard let date else { return "日時不明" }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: zoneID) ?? .current
        f.dateFormat = "yyyy/MM/dd HH:mm:ss xxx"
        return f.string(from: date)
    }

    static func fileDate(_ interval: Double) -> String {
        guard interval > 0 else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: Date(timeIntervalSince1970: interval))
    }

    /// "2026/10-28" -> ("2026", "10-28"). Anything else is shown verbatim as its own group.
    static func splitFolder(_ path: String) -> (year: String, day: String) {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].count == 4, Int(parts[0]) != nil else { return (path, path) }
        return (parts[0], parts[1])
    }

    static func kindLabel(_ item: MediaItem) -> String {
        switch item.kind {
        case .raw: return "RAW写真"
        case .photo: return "写真"
        case .video: return "動画"
        case .sidecar: return "付随ファイル"
        }
    }

    static func count(_ n: Int) -> String { "\(n.formatted())件" }

    /// Safety margin from SPEC §7: max(1 GiB, 1% of the planned total).
    static func requiredWithMargin(_ bytes: Int64) -> Int64 {
        guard bytes > 0 else { return 0 }
        return bytes + max(1 << 30, bytes / 100)
    }

    static func displayPath(_ url: URL?) -> String {
        guard let url else { return "未設定" }
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func volumeName(of url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
        return nil
    }
}
