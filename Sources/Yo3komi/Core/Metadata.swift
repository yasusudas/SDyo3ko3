import Foundation
import ImageIO
import AVFoundation

struct CaptureInfo {
    var date: Date?
    var folder: String?
    var evidence: String
    var duration: Double?
}
final class SonyXML: NSObject, XMLParserDelegate {
    var date: String?; var umid: String?; var model: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String:String]) {
        if name == "CreationDate" { date = a["value"] }
        if name == "TargetMaterial" { umid = a["umidRef"] }
        if name == "Device" { model = a["modelName"] }
    }
    static func read(_ url: URL) -> SonyXML? {
        guard let size = try? FileSystem.stamp(url).size, size < 2 * 1024 * 1024,
              let parser = XMLParser(contentsOf: url) else { return nil }
        let result = SonyXML(); parser.delegate = result; parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), result.model != nil, result.umid != nil, result.date != nil else { return nil }
        return result
    }
}
enum MetadataReader {
    static func folder(for date: Date, zone: TimeZone) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = zone; f.dateFormat="yyyy/MM-dd"; return f.string(from: date)
    }
    static func parseEXIF(_ text: String, offset: String?) -> Date? {
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.calendar=Calendar(identifier:.gregorian); f.isLenient=false
        f.timeZone=TimeZone(secondsFromGMT:0); f.dateFormat="yyyy:MM:dd HH:mm:ss"
        let base=String(text.prefix(19)); guard let date=f.date(from:base), f.string(from:date)==base else { return nil }
        if let offset, offset.range(of:"^[+-][0-9]{2}:[0-9]{2}$",options:.regularExpression) != nil {
            let sign = offset.hasPrefix("-") ? -1 : 1
            let pieces=offset.dropFirst().split(separator:":").compactMap{Int($0)}
            if pieces.count==2, pieces[0]<=23, pieces[1]<60 { return date.addingTimeInterval(Double(-sign*(pieces[0]*3600+pieces[1]*60))) }
        }
        return date
    }
    static func read(_ url: URL, kind: MediaKind, zone: TimeZone, xml: URL?) async -> CaptureInfo {
        if kind != .video {
            if let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
               let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
               let exif=props[kCGImagePropertyExifDictionary as String] as? [String:Any] {
                let raw=(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String) ?? (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String)
                let offset=exif["OffsetTimeOriginal"] as? String
                if let raw, let baseDate=parseEXIF(raw,offset:offset) {
                    let subsec=(exif["SubsecTimeOriginal"] as? String) ?? ""
                    let fraction=Double("0."+String(subsec.filter(\.isNumber).prefix(9))) ?? 0
                    let d=baseDate.addingTimeInterval(fraction)
                    // Preserve the camera calendar day even if the computer's timezone differs.
                    let parts=String(raw.prefix(10)).replacingOccurrences(of:":",with:"-").split(separator:"-")
                    if parts.count==3 { return CaptureInfo(date:d,folder:"\(parts[0])/\(parts[1])-\(parts[2])",evidence:"EXIF \(raw) \(offset ?? "（時差情報なし）")",duration:nil) }
                }
            }
            return CaptureInfo(date:nil,folder:nil,evidence:"撮影日時が見つかりません。日付を指定してください。",duration:nil)
        }
        let asset=AVURLAsset(url:url)
        let duration=(try? await asset.load(.duration)).flatMap { value -> Double? in let seconds=CMTimeGetSeconds(value); return seconds.isFinite ? seconds : nil }
        if let xml, let metadata=SonyXML.read(xml), let text=metadata.date,
           let d=ISO8601DateFormatter().date(from:text), text.count>=10 {
            let day=String(text.prefix(10)).split(separator:"-")
            if day.count==3 { return CaptureInfo(date:d,folder:"\(day[0])/\(day[1])-\(day[2])",evidence:"Sony XML CreationDate \(text)",duration:duration) }
        }
        if let metadata=try? await asset.load(.metadata) {
            for m in metadata where m.commonKey == .commonKeyCreationDate {
                if let text=try? await m.load(.stringValue), let d=ISO8601DateFormatter().date(from:text) {
                    let day=String(text.prefix(10)).split(separator:"-")
                    if day.count==3 { return CaptureInfo(date:d,folder:"\(day[0])/\(day[1])-\(day[2])",evidence:"動画撮影メタデータ \(text)",duration:duration) }
                }
            }
        }
        // AVFoundation exposes the QuickTime container creation time as an absolute date.
        if let date = try? await asset.load(.creationDate), let d = try? await date.load(.dateValue), d.timeIntervalSince1970 > -2_082_844_800 {
            return CaptureInfo(date:d,folder:folder(for:d,zone:zone),evidence:"QuickTime UTC → \(zone.identifier)（設定した撮影地時差）",duration:duration)
        }
        return CaptureInfo(date:nil,folder:nil,evidence:"動画の撮影日時を確認できません。",duration:duration)
    }
}
