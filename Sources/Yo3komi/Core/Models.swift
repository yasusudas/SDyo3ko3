import Foundation

enum SourceMode: String, Codable, CaseIterable, Identifiable {
    case camera, folder
    var id: String { rawValue }
    var title: String { self == .camera ? "カメラカード" : "通常フォルダ" }
}
enum MediaKind: String, Codable, Sendable { case photo, raw, video, sidecar }
enum ItemStatus: String, Codable, Sendable {
    case checking, new, imported, cardDuplicate, needsDate, failed, copying, verifying
    var title: String {
        switch self {
        case .checking: return "照合中"
        case .new: return "未取り込み"
        case .imported: return "取り込み済み"
        case .cardDuplicate: return "同一内容（カード内）"
        case .needsDate: return "日時の確認が必要"
        case .failed: return "失敗"
        case .copying: return "コピー中"
        case .verifying: return "検証中"
        }
    }
}
enum MediaFilter: String, CaseIterable, Identifiable {
    case all, new, imported, attention
    var id: String { rawValue }
    var title: String { switch self { case .all: return "すべて"; case .new: return "未取り込み"; case .imported: return "取り込み済み"; case .attention: return "要確認" } }
}
enum KindFilter: String, CaseIterable, Identifiable {
    case all, photos, videos
    var id: String { rawValue }
    var title: String { switch self { case .all: return "すべての形式"; case .photos: return "写真・RAW"; case .videos: return "動画" } }
}
struct FileStamp: Codable, Equatable, Sendable {
    var size: Int64
    var modified: Double
    var changed: Double
    var fileID: String
}
struct RelatedFile: Identifiable, Codable, Sendable {
    var id: String { url.path }
    var url: URL
    var stamp: FileStamp
    var targetName: String
}
struct MediaItem: Identifiable, Codable, Sendable {
    var id: String { url.path }
    var url: URL
    var relativePath: String
    var kind: MediaKind
    var stamp: FileStamp
    var captureDate: Date?
    var dateFolder: String?
    var dateEvidence: String = ""
    var duration: Double?
    var status: ItemStatus = .checking
    var isSelected = false
    var message: String = ""
    var destinationURL: URL?
    var duplicateURL: URL?
    var digest: String?
    var related: [RelatedFile] = []
    var supplementURLs: [URL] = []
    var supplementSelected = false
    var canSelect: Bool { status == .new || (status == .failed && dateFolder != nil && destinationURL != nil) }
    var isVideo: Bool { kind == .video }
    var name: String { url.lastPathComponent }
    var byteCount: Int64 { stamp.size }
    var fileExtension: String { url.pathExtension.uppercased() }
}
struct FolderSummary: Identifiable {
    var id: String { path }
    var path: String
    var count: Int
    var bytes: Int64
    var isNew: Bool
    var photos: Int
    var videos: Int
}
struct VolumeInfo: Identifiable {
    var id: String { url.path }
    var url: URL
    var name: String
    var isRemovable: Bool
}
struct ImportProgress: Sendable {
    var phase: String = ""
    var completed: Int = 0
    var total: Int = 0
    var bytesCopied: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var currentName: String = ""
    var currentID: String = ""
    var fraction: Double { totalBytes > 0 ? min(completed == total ? 1 : 0.99, Double(bytesCopied)/Double(totalBytes)) : 0 }
}
struct ScanResult: Sendable {
    var items: [MediaItem]
    var warnings: [String]
    var existingFolders: [String]
    var sourceIdentity: String
    var destinationIdentity: String
}
struct ImportOutcome: Sendable {
    var id: String
    var success: Bool
    var destination: URL?
    var message: String
    var supplementOnly: Bool = false
}
func formattedBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

enum ConnectionState: String, Sendable {
    case unconfigured, connected, disconnected, error
}
