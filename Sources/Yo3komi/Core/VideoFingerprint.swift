import Foundation
import AVFoundation
import CryptoKit

struct VideoTrackFingerprint: Codable, Equatable, Sendable {
    var mediaType: String
    var format: String
    var digest: String
    var byteCount: Int64
}

/// Encoded media essence only: no container, timestamps, orientation, or camera data tracks.
/// Concatenating bytes instead of hashing individual buffers tolerates different audio packet grouping.
struct VideoFingerprint: Codable, Equatable, Sendable {
    static let algorithm = "av-essence-sha256-v1"
    var algorithm: String = Self.algorithm
    var digest: String
    var tracks: [VideoTrackFingerprint]

    init(tracks: [VideoTrackFingerprint]) {
        self.tracks = tracks.sorted { Self.key($0) < Self.key($1) }
        digest = Self.combined(self.tracks)
    }

    private static func key(_ track: VideoTrackFingerprint) -> String {
        "\(track.mediaType)|\(track.format)|\(track.byteCount)|\(track.digest)"
    }

    private static func combined(_ tracks: [VideoTrackFingerprint]) -> String {
        let text = ([algorithm] + tracks.map(key)).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard algorithm == Self.algorithm, !tracks.isEmpty, tracks.count <= 64,
              tracks.contains(where: { $0.mediaType == "video" }),
              tracks.allSatisfy({ ["video", "audio"].contains($0.mediaType) && !$0.format.isEmpty && $0.format.count < 4096 && $0.byteCount > 0 && validSHA256($0.digest) }),
              validSHA256(digest), VideoFingerprint(tracks: tracks).digest == digest else {
            throw ImportError.message("動画の内容ハッシュの記録が不正です。")
        }
    }
}

func validSHA256(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

enum VideoFingerprintReader {
    static func read(_ url: URL) async throws -> VideoFingerprint {
        let before = try FileSystem.stamp(url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let allTracks = try await asset.load(.tracks)
        var results: [VideoTrackFingerprint] = []
        for track in allTracks {
            try Task.checkCancellation()
            let type = track.mediaType
            guard type == .video || type == .audio else { continue }
            let descriptions = try await track.load(.formatDescriptions)
            let formats = try descriptions.map { try formatSignature($0, type: type) }
            guard !formats.isEmpty else { throw ImportError.message("動画の符号化形式を確認できません: \(url.lastPathComponent)") }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ImportError.message("動画の内容を読み取れません: \(url.lastPathComponent)") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? ImportError.message("動画の読み取りを開始できません。") }
            defer { reader.cancelReading() }
            var hash = SHA256()
            var bytes: Int64 = 0
            while true {
                try Task.checkCancellation()
                let more = try autoreleasepool { () throws -> Bool in
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    defer { CMSampleBufferInvalidate(sample) }
                    if CMSampleBufferGetNumSamples(sample) == 0 { return true }
                    guard let block = CMSampleBufferGetDataBuffer(sample) else {
                        throw ImportError.message("動画に読み取れないサンプルがあります（\(type.rawValue)、\(CMSampleBufferGetNumSamples(sample))サンプル、\(CMSampleBufferGetTotalSampleSize(sample))バイト、\(url.lastPathComponent)）。")
                    }
                    let length = CMBlockBufferGetDataLength(block)
                    guard length > 0 else { throw ImportError.message("動画に空のサンプルがあります。") }
                    // Bound transient storage even for unusually large intra frames.
                    var offset = 0
                    while offset < length {
                        let count = min(8 * 1024 * 1024, length - offset)
                        var data = Data(count: count)
                        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: count, destination: $0.baseAddress!) }
                        guard status == kCMBlockBufferNoErr else { throw ImportError.message("動画のサンプルを読み取れません。") }
                        hash.update(data: data)
                        offset += data.count
                    }
                    bytes += Int64(length)
                    return true
                }
                if !more { break }
            }
            guard reader.status == .completed, bytes > 0 else {
                throw reader.error ?? ImportError.message("動画を最後まで読み取れません: \(url.lastPathComponent)")
            }
            results.append(VideoTrackFingerprint(mediaType: type == .video ? "video" : "audio",
                                                  format: Array(Set(formats)).sorted().joined(separator: ";"),
                                                  digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: bytes))
        }
        guard before == (try FileSystem.stamp(url)) else { throw ImportError.message("動画の照合中にファイルが変更されました。") }
        let result = VideoFingerprint(tracks: results)
        try result.validate()
        return result
    }

    private static func formatSignature(_ description: CMFormatDescription, type: AVMediaType) throws -> String {
        var parts = [String(CMFormatDescriptionGetMediaSubType(description))]
        if type == .video {
            let size = CMVideoFormatDescriptionGetDimensions(description)
            parts += [String(size.width), String(size.height)]
            if let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                for key in ["avcC", "hvcC", "av1C", "vpcC", "esds"].sorted() {
                    if let data = atoms[key] as? Data { parts.append(key + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()) }
                }
            }
        } else if let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let audio = pointer.pointee
            parts += [String(audio.mSampleRate), String(audio.mChannelsPerFrame), String(audio.mBitsPerChannel), String(audio.mFormatFlags)]
            var size = 0
            if let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 {
                parts.append(SHA256.hash(data: Data(bytes: cookie, count: size)).map { String(format: "%02x", $0) }.joined())
            }
        } else { throw ImportError.message("動画の音声形式を確認できません。") }
        return parts.joined(separator: ":")
    }
}
