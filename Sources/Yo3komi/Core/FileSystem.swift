import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

enum ImportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
enum FileSystem {
    private static let processSessionID=UUID().uuidString
    static let mediaExtensions: Set<String> = ["arw","jpg","jpeg","mp4","mov","dng","tif","tiff","heic","heif","png","cr2","cr3","nef","nrw","raf","orf","rw2","pef","srw"]
    static let rawExtensions: Set<String> = ["arw","dng","cr2","cr3","nef","nrw","raf","orf","rw2","pef","srw"]
    static func kind(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if ["xmp","xml"].contains(ext) { return .sidecar }
        if rawExtensions.contains(ext) { return .raw }
        if ["mp4","mov"].contains(ext) { return .video }
        if mediaExtensions.contains(ext) { return .photo }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .photo }
        return nil
    }
    static func stamp(_ url: URL) throws -> FileStamp {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw ImportError.message("ファイルを読み取れません: \(url.lastPathComponent)")
        }
        return FileStamp(size: Int64(st.st_size), modified: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec)/1e9,
                         changed: Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec)/1e9, fileID: "\(st.st_ino)")
    }
    static func identity(_ url: URL) throws -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImportError.message("フォルダを確認してください: \(url.path)") }
        var st = stat()
        guard stat(resolved.path, &st) == 0 else { throw ImportError.message("ストレージが接続されていません。") }
        if let uuid = values.volumeUUIDString { return "\(uuid):\(st.st_ino)" }
        // No reliable persistent volume identifier: never silently reuse a different device.
        return "session:\(processSessionID):\(st.st_dev):\(st.st_ino):\(st.st_birthtimespec.tv_sec)"
    }
    static func validateRoots(_ source: URL, _ destination: URL) throws {
        let s = source.resolvingSymlinksInPath().standardizedFileURL.path
        let d = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard s != "/", d != "/", s != d, !s.hasPrefix(d + "/"), !d.hasPrefix(s + "/") else { throw ImportError.message("取り込み元と保存先は、互いに含まれない別のフォルダを選んでください。") }
        _ = try identity(source); _ = try identity(destination)
        guard FileManager.default.isReadableFile(atPath: source.path), FileManager.default.isWritableFile(atPath: destination.path) else { throw ImportError.message("フォルダへのアクセス権を確認してください。") }
    }
    static func enumerate(_ root: URL) throws -> [URL] {
        var failure: Error?
        let rootVolume = try root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier.map { String(describing: $0) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.isAliasFileKey,.volumeIdentifierKey], options: [.skipsHiddenFiles,.skipsPackageDescendants], errorHandler: { _, error in failure = error; return false }) else { throw ImportError.message("フォルダを走査できません: \(root.path)") }
        var files: [URL] = []
        while let u = e.nextObject() as? URL {
            try Task.checkCancellation()
            let v = try u.resourceValues(forKeys: [.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey,.isAliasFileKey,.volumeIdentifierKey])
            if v.isSymbolicLink == true || v.isAliasFile == true { e.skipDescendants(); continue }
            if let volume = v.volumeIdentifier, let rootVolume, String(describing: volume) != rootVolume { e.skipDescendants(); continue }
            if v.isRegularFile == true { files.append(u) }
        }
        if let failure { throw failure }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    static func digest(_ url: URL) throws -> String {
        let before = try stamp(url)
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try autoreleasepool(invoking: { try f.read(upToCount: 8 * 1024 * 1024) }), !data.isEmpty else { break }
            hash.update(data: data)
        }
        guard before == (try stamp(url)) else { throw ImportError.message("読み取り中にファイルが変更されました: \(url.lastPathComponent)") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func sample(_ url: URL, size: Int64) throws -> String {
        let before = try stamp(url)
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var h = SHA256(); let block: Int64 = 64 * 1024
        for position in Set([Int64(0), max(0, size/2-block/2), max(0,size-block)]).sorted() {
            try Task.checkCancellation(); try f.seek(toOffset: UInt64(position))
            if let data = try f.read(upToCount: Int(min(block,max(0,size-position)))) { h.update(data: data) }
        }
        guard before == (try stamp(url)) else { throw ImportError.message("ファイルが変更されました。") }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func safeDirectory(_ relative: String, in root: URL) throws -> URL {
        var current = root
        for component in relative.split(separator: "/").map(String.init) {
            guard component != "..", component != "." else { throw ImportError.message("保存パスが不正です。") }
            current.appendPathComponent(component, isDirectory: true)
            var st = stat()
            if lstat(current.path, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ImportError.message("保存先の階層にリンクまたは同名ファイルがあります。") }
            } else {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        return current
    }
    static func appSupport() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("yo3komi", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func available(_ url: URL) -> Int64 {
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let b = v.volumeAvailableCapacityForImportantUsage { return b }
        return ((try? FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
    }
}
