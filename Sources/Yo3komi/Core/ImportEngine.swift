import Foundation
import CryptoKit
import Darwin

struct ScanRequest: Sendable {
    var source: URL; var destination: URL; var mode: SourceMode
    var dcim: Bool; var clip: Bool; var timeZone: String; var force: Bool
}

/// A read-only comparison of scan inputs. Never rebases the stricter import manifests or hash caches.
struct ScanObservation: Equatable {
    let source: URL
    let destination: URL
    let mode: SourceMode
    let dcim: Bool
    let clip: Bool
    let timeZone: String
    let sourceIdentity: String
    let destinationIdentity: String
    let sourceFiles: [String: FileStamp]
    let destinationFiles: [String: FileStamp]
    let folders: Set<String>

    init(request: ScanRequest, sourceIdentity: String, destinationIdentity: String,
         sourceFiles: [String: FileStamp], destinationFiles: [String: FileStamp], folders: Set<String>) {
        source = request.source; destination = request.destination
        mode = request.mode; dcim = request.dcim; clip = request.clip; timeZone = request.timeZone
        self.sourceIdentity = sourceIdentity; self.destinationIdentity = destinationIdentity
        self.sourceFiles = Self.relevantFiles(sourceFiles)
        self.destinationFiles = Self.relevantFiles(destinationFiles)
        self.folders = folders
    }

    func matchesRequest(_ request: ScanRequest) -> Bool {
        source == request.source && destination == request.destination && mode == request.mode &&
            dcim == request.dcim && clip == request.clip && timeZone == request.timeZone
    }

    static func relevantFiles(_ files: [String: FileStamp]) -> [String: FileStamp] {
        files.filter { FileSystem.kind(URL(fileURLWithPath: $0.key)) != nil }
    }

    static func sourceRoots(_ request: ScanRequest, warnings: inout [String]) throws -> [URL] {
        guard request.mode == .camera else { return [request.source] }
        var roots: [URL] = []
        for (enabled, path) in [(request.dcim, "DCIM"), (request.clip, "PRIVATE/M4ROOT/CLIP")] where enabled {
            let url = request.source.appendingPathComponent(path, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                roots.append(url)
            } else { warnings.append("\(path) が見つかりません。") }
        }
        guard !roots.isEmpty else { throw ImportError.message("探索対象のDCIM/CLIPがありません。元フォルダか探索方式を確認してください。") }
        return roots
    }

    static func destinationFolders(_ destination: URL, files: [URL]) throws -> Set<String> {
        var folders = Set<String>()
        for year in try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
            try Task.checkCancellation()
            guard year.lastPathComponent.range(of: "^[0-9]{4}$", options: .regularExpression) != nil,
                  let values = try? year.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for day in try FileManager.default.contentsOfDirectory(at: year, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
                let values = try day.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true,
                   day.lastPathComponent.range(of: "^[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
                    folders.insert(year.lastPathComponent + "/" + day.lastPathComponent)
                }
            }
        }
        for url in files {
            try Task.checkCancellation()
            let components = url.deletingLastPathComponent().path.replacingOccurrences(of: destination.path + "/", with: "").split(separator: "/")
            if components.count >= 2, components[0].count == 4, components[1].count == 5 {
                folders.insert("\(components[0])/\(components[1])")
            }
        }
        return folders
    }

    static func capture(_ request: ScanRequest) throws -> ScanObservation {
        try FileSystem.validateRoots(request.source, request.destination)
        let sourceIdentity = try FileSystem.identity(request.source)
        let destinationIdentity = try FileSystem.identity(request.destination)
        let destinationURLs = try FileSystem.enumerate(request.destination)
        var warnings: [String] = []
        let sourceURLs = try sourceRoots(request, warnings: &warnings).flatMap { try FileSystem.enumerate($0) }
        func stamps(_ urls: [URL]) throws -> [String: FileStamp] {
            var result: [String: FileStamp] = [:]
            for url in urls where FileSystem.kind(url) != nil {
                try Task.checkCancellation()
                result[url.path] = try FileSystem.stamp(url)
            }
            return result
        }
        let result = try ScanObservation(request: request, sourceIdentity: sourceIdentity, destinationIdentity: destinationIdentity,
                                         sourceFiles: stamps(sourceURLs), destinationFiles: stamps(destinationURLs),
                                         folders: destinationFolders(request.destination, files: destinationURLs))
        guard sourceIdentity == (try FileSystem.identity(request.source)),
              destinationIdentity == (try FileSystem.identity(request.destination)) else {
            throw ImportError.message("確認中にストレージが変更されました。再読み込みしてください。")
        }
        return result
    }
}
struct ScanUpdate: Sendable {
    var items: [MediaItem]? = nil
    var changed: [MediaItem] = []
    var completed: Int = 0; var total: Int = 0; var message: String
}
struct JobRecord: Codable {
    var id: String; var sourceRoot: URL; var destinationRoot: URL
    var sourceIdentity: String; var destinationIdentity: String
    var items: [MediaItem]; var completed: [String] = []
    var ownedTemporaryPaths: [String] = []
    var outcomes: [ImportOutcomeRecord] = []
    var finished = false
}
struct ImportOutcomeRecord: Codable { var path: String; var destination: String?; var message: String; var success: Bool }

actor ImportEngine {
    private var index: HashIndex?
    private var history:ImportHistory?
    private var manifest: [String:FileStamp] = [:]
    private var sourceManifest:[String:FileStamp]=[:]
    private var lastRequest: ScanRequest?
    private var sourceIdentity = ""; private var destinationIdentity = ""
    private var samples: [String:String] = [:]; private var hashes: [String:String] = [:]
    private var lastCleanScan = false
    private var lastObservation: ScanObservation?
    private var videoFingerprints: [String: VideoFingerprint] = [:]

    private func openedHistory() throws -> ImportHistory {
        if history == nil { history = try ImportHistory() }
        return history!
    }
    func historySummary() throws -> HistorySummary { try openedHistory().summary() }
    func exportHistory(to url: URL) throws -> Int { try openedHistory().exportFile(to: url) }
    func importHistory(from url: URL) throws -> HistoryMergeResult {
        let result = try openedHistory().importFile(from: url)
        lastCleanScan = false
        return result
    }

    func hasRelevantChanges(_ request: ScanRequest) throws -> Bool {
        guard lastCleanScan, let previous = lastObservation, previous.matchesRequest(request) else { return true }
        return try ScanObservation.capture(request) != previous
    }

    func scan(_ request: ScanRequest, update: @escaping @Sendable (ScanUpdate) async -> Void) async throws -> ScanResult {
        try FileSystem.validateRoots(request.source,request.destination)
        let sourceID=try FileSystem.identity(request.source), destID=try FileSystem.identity(request.destination)
        sourceIdentity=sourceID; destinationIdentity=destID; lastRequest=request; lastCleanScan=false
        samples.removeAll(); hashes.removeAll(); manifest.removeAll();sourceManifest.removeAll()
        videoFingerprints.removeAll()
        if index == nil { index=try? HashIndex() }
        if history == nil {history=try ImportHistory()}
        var warnings: [String]=[]
        if index == nil { warnings.append("永続索引を利用できないため、内容を直接照合します。") }
        await update(ScanUpdate(message:"保存先のファイルを確認中…"))
        let destinationFiles=try FileSystem.enumerate(request.destination)
        var sizeMap: [Int64:[URL]]=[:]
        let folders=try ScanObservation.destinationFolders(request.destination, files: destinationFiles)
        for url in destinationFiles {
            try Task.checkCancellation()
            let stamp=try FileSystem.stamp(url); manifest[url.path]=stamp
            if let kind=FileSystem.kind(url), kind != .sidecar { sizeMap[stamp.size,default:[]].append(url) }
        }
        let roots=try ScanObservation.sourceRoots(request, warnings: &warnings)
        var files: [URL]=[]
        for root in roots { files += try FileSystem.enumerate(root) }
        for file in files {sourceManifest[file.path]=try FileSystem.stamp(file)}
        let byDirectory=Dictionary(grouping:files,by:{$0.deletingLastPathComponent().path})
        var items: [MediaItem]=[]
        for url in files {
            guard let kind=FileSystem.kind(url),kind != .sidecar else { continue }
            do {
                let stamp=try FileSystem.stamp(url)
                items.append(MediaItem(url:url,relativePath:String(url.path.dropFirst(request.source.path.count+1)),kind:kind,stamp:stamp))
            } catch { warnings.append(error.localizedDescription) }
        }
        await update(ScanUpdate(items:items,total:items.count,message:"撮影日時と重複を照合中…"))
        // One-time adoption of the existing archive. Stable fingerprints reuse full hashes later.
        let archiveMedia=destinationFiles.filter{if let kind=FileSystem.kind($0){return kind != .sidecar};return false}
        var archiveVideos: [String: URL] = [:]
        for (n,url) in archiveMedia.enumerated() {
            try Task.checkCancellation()
            guard let stamp=manifest[url.path] else{continue}
            let hash=try digest(url,stamp:stamp,rootID:destID,force:request.force)
            let path=String(url.path.dropFirst(request.destination.path.count+1))
            var video: VideoFingerprint?
            if FileSystem.kind(url) == .video {
                do {
                    video = try await videoFingerprint(url, stamp: stamp, rootID: destID, force: request.force)
                    archiveVideos[video!.digest] = url
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append("動画の内容照合を保留（ファイル全体の一致のみ照合）: \(url.lastPathComponent)・\(error.localizedDescription)") }
            }
            try history?.record(digest:hash,size:stamp.size,name:url.lastPathComponent,source:nil,destination:url,folder:String(path.split(separator:"/").prefix(2).joined(separator:"/")),origin:"existing-archive",video:video)
            if n % 16 == 0 || n==archiveMedia.count-1 {await update(ScanUpdate(completed:n+1,total:archiveMedia.count,message:"保存先の取り込み履歴を確認中 \(n+1) / \(archiveMedia.count)（初回は全内容を読み取ります）"))}
        }
        var sourceBySize: [Int64:[Int]]=[:]
        var sourceVideos = Set<String>()
        let zone=TimeZone(identifier:request.timeZone) ?? TimeZone(identifier:"Asia/Tokyo")!
        var changed: [MediaItem]=[]
        for i in items.indices {
            try Task.checkCancellation()
            var item=items[i]
            do {
                let siblings=byDirectory[item.url.deletingLastPathComponent().path] ?? []
                let stem=item.url.deletingPathExtension().lastPathComponent
                var xml: URL?
                for u in siblings {
                    let ext=u.pathExtension.lowercased()
                    if ext=="xmp",u.deletingPathExtension().lastPathComponent==stem {
                        item.related.append(RelatedFile(url:u,stamp:try FileSystem.stamp(u),targetName:u.lastPathComponent))
                    }
                    if item.isVideo,ext=="xml",u.lastPathComponent.caseInsensitiveCompare(stem+"M01.XML") == .orderedSame,SonyXML.read(u) != nil {
                        xml=u; item.related.append(RelatedFile(url:u,stamp:try FileSystem.stamp(u),targetName:u.lastPathComponent))
                    }
                }
                let metadata=await MetadataReader.read(item.url,kind:item.kind,zone:zone,xml:xml)
                item.captureDate=metadata.date; item.dateFolder=metadata.folder; item.dateEvidence=metadata.evidence; item.duration=metadata.duration
                var duplicate: URL?
                if let candidates=sizeMap[item.stamp.size] {
                    let sample=try sample(item.url,stamp:item.stamp,rootID:sourceID,force:request.force)
                    for candidate in candidates {
                        guard let stamp=manifest[candidate.path] else { continue }
                        if sample != (try self.sample(candidate,stamp:stamp,rootID:destID,force:request.force)) { continue }
                        let hash=try digest(item.url,stamp:item.stamp,rootID:sourceID,force:request.force)
                        if hash == (try digest(candidate,stamp:stamp,rootID:destID,force:request.force)) { duplicate=candidate; item.digest=hash; break }
                    }
                }
                var past:HistoryRecord?
                if duplicate == nil,history?.hasSize(item.stamp.size)==true {
                    let hash=try digest(item.url,stamp:item.stamp,rootID:sourceID,force:request.force)
                    item.digest=hash;past=try history?.lookup(hash,size:item.stamp.size)
                }
                var videoEquivalent = false
                if item.isVideo {
                    let video = try await videoFingerprint(item.url, stamp: item.stamp, rootID: sourceID, force: request.force)
                    item.videoFingerprint = video
                    if duplicate == nil, past == nil, let record = try history?.lookupVideo(video) {
                        past = record
                        duplicate = archiveVideos[video.digest]
                        videoEquivalent = true
                    }
                    // Preserve the original byte hash as an alias too, even if a transformed copy matched.
                    if duplicate != nil || past != nil {
                        let hash = try digest(item.url, stamp: item.stamp, rootID: sourceID, force: request.force)
                        item.digest = hash
                        let target = duplicate ?? URL(fileURLWithPath: past!.destinationPath)
                        try history?.record(digest: hash, size: item.stamp.size, name: item.name, source: item.url,
                                            destination: target, folder: item.dateFolder, origin: videoEquivalent ? "video-equivalent" : "existing-archive", video: video)
                    }
                }
                if let past, duplicate == nil {
                    item.status = .imported;item.isSelected=false
                    item.message=(videoEquivalent ? "取り込み履歴あり（映像・音声のSHA-256一致）。" : "取り込み履歴あり（SHA-256一致）。")+"保存先から削除・移動されていても再取り込みしません。記録名: \(past.originalName)"
                } else if let duplicate {
                    item.status = .imported; item.duplicateURL=duplicate; item.destinationURL=duplicate
                    if videoEquivalent { item.message = "映像・音声のSHA-256一致。コンテナやメタデータが異なっていても取り込み済みです。" }
                    // A transformed video must not receive a camera XML describing the original container.
                    for r in item.related.indices where !videoEquivalent {
                        item.related[r].targetName=relatedName(item.related[r],for:item,final:duplicate)
                        let related=item.related[r]
                        if duplicate.lastPathComponent != item.name, xmlReferencesOriginalName(item),related.url.pathExtension.lowercased()=="xml" {item.message="XML内のファイル参照が異なるため補完を保留します。";continue}
                        let target=duplicate.deletingLastPathComponent().appendingPathComponent(related.targetName)
                        if !FileManager.default.fileExists(atPath:target.path) { item.supplementURLs.append(related.url) }
                        else if let s=try? FileSystem.stamp(target),s.size != related.stamp.size { item.message="既存の付随ファイルは異なるため補完を保留します。" }
                    }
                } else {
                    var identicalSource = item.videoFingerprint.map { sourceVideos.contains($0.digest) } ?? false
                    if identicalSource { item.message = "映像・音声が同一の動画がカード内にあります。" }
                    for previous in sourceBySize[item.stamp.size] ?? [] {
                        let p=items[previous]
                        if try sample(item.url,stamp:item.stamp,rootID:sourceID,force:request.force) != sample(p.url,stamp:p.stamp,rootID:sourceID,force:request.force) { continue }
                        if try digest(item.url,stamp:item.stamp,rootID:sourceID,force:request.force) == digest(p.url,stamp:p.stamp,rootID:sourceID,force:request.force) {
                            identicalSource=true; item.message="代表: \(p.relativePath)"; break
                        }
                    }
                    if identicalSource { item.status = .cardDuplicate }
                    else if item.dateFolder == nil { item.status = .needsDate; item.message=metadata.evidence }
                    else { item.status = .new; item.isSelected=true }
                }
                if let video = item.videoFingerprint { sourceVideos.insert(video.digest) }
                sourceBySize[item.stamp.size,default:[]].append(i)
            } catch is CancellationError { throw CancellationError() }
            catch { item.status = .failed; item.message=error.localizedDescription; item.isSelected=false }
            items[i]=item; changed.append(item)
            if changed.count>=16 || i==items.count-1 {
                await update(ScanUpdate(changed:changed,completed:i+1,total:items.count,message:"重複照合 \(i+1) / \(items.count)")); changed.removeAll(keepingCapacity:true)
            }
        }
        guard sourceID == (try FileSystem.identity(request.source)), destID == (try FileSystem.identity(request.destination)) else { throw ImportError.message("走査中にストレージが変更されました。再読み込みしてください。") }
        assignDestinations(&items,root:request.destination)
        lastObservation=ScanObservation(request:request,sourceIdentity:sourceID,destinationIdentity:destID,
                                        sourceFiles:sourceManifest,destinationFiles:manifest,folders:folders)
        lastCleanScan=true
        return ScanResult(items:items,warnings:warnings,existingFolders:folders.sorted(),sourceIdentity:sourceID,destinationIdentity:destID)
    }
    private func videoFingerprint(_ url: URL, stamp: FileStamp, rootID: String, force: Bool) async throws -> VideoFingerprint {
        guard try FileSystem.stamp(url) == stamp else { throw ImportError.message("照合中に動画が変更されました。") }
        if let cached = videoFingerprints[url.path] { return cached }
        let key = rootID + "|" + url.path
        if !force, rootID != sourceIdentity, !rootID.hasPrefix("session:"), let cached = index?.video(key, stamp: stamp) {
            videoFingerprints[url.path] = cached
            return cached
        }
        let result = try await VideoFingerprintReader.read(url)
        guard try FileSystem.stamp(url) == stamp else { throw ImportError.message("照合中に動画が変更されました。") }
        videoFingerprints[url.path] = result
        index?.saveVideo(key, stamp: stamp, value: result)
        return result
    }
    private func sample(_ url: URL,stamp: FileStamp,rootID: String,force: Bool) throws -> String {
        guard try FileSystem.stamp(url)==stamp else{throw ImportError.message("照合中にファイルが変更されました。再読み込みしてください。") }
        if let cached=samples[url.path] { return cached }
        let key=rootID+"|"+url.path
        if !force,!rootID.hasPrefix("session:"),let cached=index?.lookup(key,stamp:stamp)?.0 { samples[url.path]=cached; return cached }
        let s=try FileSystem.sample(url,size:stamp.size); samples[url.path]=s
        let preservedDigest = hashes[url.path] ?? (force ? nil : index?.lookup(key,stamp:stamp)?.1)
        index?.save(key,stamp:stamp,sample:s,digest:preservedDigest); return s
    }
    private func digest(_ url: URL,stamp: FileStamp,rootID: String,force: Bool) throws -> String {
        guard try FileSystem.stamp(url)==stamp else{throw ImportError.message("照合中にファイルが変更されました。再読み込みしてください。") }
        if let cached=hashes[url.path] { return cached }
        let key=rootID+"|"+url.path
        if !force,rootID != sourceIdentity,!rootID.hasPrefix("session:"),let cached=index?.lookup(key,stamp:stamp)?.1 { hashes[url.path]=cached; return cached }
        let hash=try FileSystem.digest(url); hashes[url.path]=hash
        index?.save(key,stamp:stamp,sample:samples[url.path],digest:hash); return hash
    }
    func assignDestinations(_ items: inout [MediaItem],root: URL) {
        var reserved=Set<String>()
        for i in items.indices where items[i].status == .new || items[i].status == .failed {
            guard let folder=items[i].dateFolder else { continue }
            let dir=root.appendingPathComponent(folder,isDirectory:true)
            var target=dir.appendingPathComponent(items[i].name); var n=2
            while FileManager.default.fileExists(atPath:target.path) || reserved.contains(target.path.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))) {
                let stem=items[i].url.deletingPathExtension().lastPathComponent
                target=dir.appendingPathComponent("\(stem)_\(n).\(items[i].url.pathExtension)"); n+=1
            }
            if target.lastPathComponent != items[i].name, xmlReferencesOriginalName(items[i]) {
                items[i].status = .failed; items[i].isSelected=false; items[i].message="同名動画があり、XMLとの関連を保つため確認が必要です。"; continue
            }
            items[i].destinationURL=target
            reserved.insert(target.path.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX")))
        }
    }
    private func xmlReferencesOriginalName(_ item:MediaItem)->Bool {
        item.related.contains { r in
            guard r.url.pathExtension.lowercased()=="xml" else{return false}
            guard let text=try? String(contentsOf:r.url,encoding:.utf8) else{return true}
            return text.localizedCaseInsensitiveContains(item.name)
        }
    }
    private func relatedName(_ related:RelatedFile,for item:MediaItem,final:URL)->String {
        guard final.lastPathComponent != item.name else{return related.targetName}
        let ext=related.url.pathExtension
        if ext.lowercased()=="xmp" {return final.deletingPathExtension().lastPathComponent+"."+ext}
        if ext.lowercased()=="xml",related.url.lastPathComponent.caseInsensitiveCompare(item.url.deletingPathExtension().lastPathComponent+"M01.XML") == .orderedSame {
            return final.deletingPathExtension().lastPathComponent+"M01."+ext
        }
        return related.targetName
    }
    func preflight(_ items: [MediaItem],source: URL,destination: URL) throws {
        guard lastCleanScan,let request=lastRequest,request.source==source,request.destination==destination else { throw ImportError.message("取り込み前に再読み込みしてください。") }
        try FileSystem.validateRoots(source,destination)
        guard sourceIdentity == (try FileSystem.identity(source)), destinationIdentity == (try FileSystem.identity(destination)) else { throw ImportError.message("媒体が変わりました。再読み込みしてください。") }
        var current: [String:FileStamp]=[:]
        for u in try FileSystem.enumerate(destination) { current[u.path]=try FileSystem.stamp(u) }
        guard current==manifest else { throw ImportError.message("保存先の内容が走査後に変わりました。再読み込みしてから取り込んでください。") }
        for (path,stamp) in sourceManifest {guard try FileSystem.stamp(URL(fileURLWithPath:path))==stamp else{throw ImportError.message("取り込み元が走査後に変わりました。再読み込みしてください。")}}
        for item in items {
            guard try FileSystem.stamp(item.url)==item.stamp else { throw ImportError.message("元ファイルが変更されました。再読み込みしてください。") }
            for r in item.related { guard try FileSystem.stamp(r.url)==r.stamp else { throw ImportError.message("付随ファイルが変更されました。") } }
        }
    }
    func runImport(items: [MediaItem],source: URL,destination: URL,
                   progress: @escaping @Sendable (ImportProgress) async -> Void,
                   outcome: @escaping @Sendable (ImportOutcome) async -> Void) async throws {
        try preflight(items,source:source,destination:destination)
        var job=JobRecord(id:UUID().uuidString,sourceRoot:source,destinationRoot:destination,sourceIdentity:sourceIdentity,destinationIdentity:destinationIdentity,items:items)
        let uniqueSidecars=Dictionary(items.flatMap { item -> [(String,Int64)] in
            item.related.filter { !item.status.isImported || item.supplementURLs.contains($0.url) }.map{($0.url.path,$0.stamp.size)}
        },uniquingKeysWith:{a,_ in a})
        let total=items.filter{$0.isSelected}.reduce(Int64(0)){$0+$1.byteCount}+uniqueSidecars.values.reduce(0,+)
        guard FileSystem.available(destination)>total+max(1_073_741_824,total/100) else { throw ImportError.message("保存先の空き容量が足りません。必要: \(formattedBytes(total)) ＋余裕容量") }
        try saveJob(job)
        var state=ImportProgress(phase:"コピー中",total:items.count,totalBytes:total)
        var completedSidecars=Set<String>()
        for item in items {
            try Task.checkCancellation()
            do {
                guard sourceIdentity == (try FileSystem.identity(source)),destinationIdentity == (try FileSystem.identity(destination)) else { throw ImportError.message("ストレージの接続が変わりました。") }
                state.currentName=item.name;state.currentID=item.id
                let supplementary = !item.isSelected && item.supplementSelected
                var finalURL=item.duplicateURL
                if !supplementary {
                    guard let folder=item.dateFolder else { throw ImportError.message("撮影日が未確定です。") }
                    let dir=try FileSystem.safeDirectory(folder,in:destination)
                    let proposed=item.destinationURL ?? dir.appendingPathComponent(item.name)
                    finalURL=try await copy(item.url,to:proposed,expected:item.stamp,job:&job,state:&state,progress:progress,allowRename:!xmlReferencesOriginalName(item))
                }
                guard let finalURL else { throw ImportError.message("補完先を確認できません。") }
                var sidecarError: String?
                for related in item.related {
                    if supplementary && !item.supplementURLs.contains(related.url) { continue }
                    if completedSidecars.contains(related.url.path) { continue }
                    let name=supplementary ? related.targetName : relatedName(related,for:item,final:finalURL)
                    let target=finalURL.deletingLastPathComponent().appendingPathComponent(name)
                    do {
                        if FileManager.default.fileExists(atPath:target.path) {
                            guard try FileSystem.stamp(target).size==related.stamp.size, try FileSystem.digest(target)==FileSystem.digest(related.url) else { throw ImportError.message("付随ファイルが競合しています: \(name)") }
                        } else { _ = try await copy(related.url,to:target,expected:related.stamp,job:&job,state:&state,progress:progress,allowRename:false) }
                        completedSidecars.insert(related.url.path)
                    } catch { sidecarError=error.localizedDescription }
                }
                let success=sidecarError==nil
                let message=sidecarError.map{"メディア保存済み・付随ファイル失敗: \($0)"} ?? "保存と内容検証が完了しました。"
                job.completed.append(item.id); job.outcomes.append(ImportOutcomeRecord(path:item.url.path,destination:finalURL.path,message:message,success:success)); try saveJob(job)
                await outcome(ImportOutcome(id:item.id,success:success,destination:finalURL,message:message,supplementOnly:supplementary))
                state.completed+=1; await progress(state)
            } catch is CancellationError { try saveJob(job); throw CancellationError() }
            catch {
                job.outcomes.append(ImportOutcomeRecord(path:item.url.path,destination:nil,message:error.localizedDescription,success:false)); try saveJob(job)
                await outcome(ImportOutcome(id:item.id,success:false,destination:nil,message:error.localizedDescription))
                // I/O failure pauses this batch. Do not plow through a disconnected medium.
                throw error
            }
        }
        job.finished=job.ownedTemporaryPaths.isEmpty && job.outcomes.allSatisfy(\.success); try saveJob(job); lastCleanScan=false
    }
    private func copy(_ source: URL,to proposed: URL,expected: FileStamp,job: inout JobRecord,state: inout ImportProgress,
                      progress: @escaping @Sendable (ImportProgress) async -> Void,allowRename: Bool) async throws -> URL {
        guard try FileSystem.stamp(source)==expected else { throw ImportError.message("コピー元が変更されました。") }
        let temp=proposed.deletingLastPathComponent().appendingPathComponent(".yo3komi-\(job.id)-\(UUID().uuidString).partial")
        job.ownedTemporaryPaths.append(temp.path); try saveJob(job)
        let fd=open(temp.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else { throw ImportError.message("保存先に途中ファイルを作成できません。") }
        let output=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        let input=try FileHandle(forReadingFrom:source)
        defer { try? input.close(); try? output.close() }
        var hash=SHA256(); var copied:Int64=0; let start=Date(); var last=Date.distantPast
        state.phase="コピー中"
        while true {
            try Task.checkCancellation()
            guard let data=try autoreleasepool(invoking: { try input.read(upToCount:8*1024*1024) }),!data.isEmpty else { break }
            try output.write(contentsOf:data); hash.update(data:data); copied+=Int64(data.count); state.bytesCopied+=Int64(data.count)
            if Date().timeIntervalSince(last)>=0.15 {
                state.bytesPerSecond=Double(copied)/max(0.1,Date().timeIntervalSince(start)); await progress(state); last=Date()
            }
        }
        try output.synchronize(); try output.close()
        guard copied==expected.size,try FileSystem.stamp(source)==expected else { throw ImportError.message("コピー中に元ファイルが変更されたか、読み取りが途切れました。") }
        state.phase="検証中"; state.bytesPerSecond=0; await progress(state)
        let digest=hash.finalize().map{String(format:"%02x",$0)}.joined()
        guard try FileSystem.digest(temp)==digest else { throw ImportError.message("保存内容が一致しません: \(source.lastPathComponent)") }
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:expected.modified)],ofItemAtPath:temp.path)
        var target=proposed; var n=2
        while renamex_np(temp.path,target.path,UInt32(RENAME_EXCL)) != 0 {
            guard errno==EEXIST,allowRename else { throw ImportError.message("保存名が競合しているか、ファイルを確定できません: \(target.lastPathComponent)") }
            target=proposed.deletingLastPathComponent().appendingPathComponent("\(proposed.deletingPathExtension().lastPathComponent)_\(n).\(proposed.pathExtension)"); n+=1
        }
        job.ownedTemporaryPaths.removeAll{$0==temp.path}; try saveJob(job)
        let finalStamp=try FileSystem.stamp(target)
        if let kind=FileSystem.kind(source),kind != .sidecar {
            let video = kind == .video ? videoFingerprints[source.path] : nil
            // This hash describes the copied bytes: copying and full readback were verified above.
            try history?.record(digest:digest,size:finalStamp.size,name:source.lastPathComponent,source:source,destination:target,folder:String(target.deletingLastPathComponent().path.dropFirst(job.destinationRoot.path.count+1)),origin:"verified-import",video:video)
            if let video { index?.saveVideo(destinationIdentity+"|"+target.path, stamp:finalStamp, value:video) }
        }
        index?.save(destinationIdentity+"|"+target.path,stamp:finalStamp,sample:nil,digest:digest)
        return target
    }
    private func saveJob(_ job: JobRecord) throws {
        let dir=try FileSystem.appSupport().appendingPathComponent("Jobs",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let data=try JSONEncoder().encode(job); try data.write(to:dir.appendingPathComponent(job.id+".json"),options:.atomic)
    }
    func recover() -> Int {
        guard let root=try? FileSystem.appSupport().appendingPathComponent("Jobs"),let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) else { return 0 }
        return files.compactMap{try? Data(contentsOf:$0)}.compactMap{try? JSONDecoder().decode(JobRecord.self,from:$0)}.filter{!$0.finished}.count
    }
    /// Explicit user action: remove only temporary files whose ownership and root are recorded.
    func clearRecovery() throws {
        let dir=try FileSystem.appSupport().appendingPathComponent("Jobs")
        for file in (try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)) ?? [] {
            guard var job=try? JSONDecoder().decode(JobRecord.self,from:Data(contentsOf:file)),!job.finished else { continue }
            guard (try? FileSystem.identity(job.destinationRoot))==job.destinationIdentity else { continue }
            for name in job.ownedTemporaryPaths {
                let u=URL(fileURLWithPath:name)
                guard u.lastPathComponent.hasPrefix(".yo3komi-\(job.id)-"),u.path.hasPrefix(job.destinationRoot.path+"/"),u.resolvingSymlinksInPath().path==u.standardizedFileURL.path else { continue }
                if FileManager.default.fileExists(atPath:name) { _=try FileSystem.stamp(u); try FileManager.default.removeItem(at:u) }
            }
            job.ownedTemporaryPaths=[]; job.finished=true; try saveJob(job)
        }
    }
}
private extension ItemStatus { var isImported: Bool { self == .imported } }
