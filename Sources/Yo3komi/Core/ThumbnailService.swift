import AppKit
import AVFoundation
import ImageIO
import CryptoKit

actor ThumbnailService {
    static let shared=ThumbnailService()
    private let memory=NSCache<NSString,NSImage>()
    private var active=0
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    private var pruned=false
    private var writes=0
    init() { memory.totalCostLimit=256*1024*1024; memory.countLimit=1400 }
    func thumbnail(for url: URL,maxPixelSize: Int) async -> NSImage? {
        guard !Task.isCancelled,let stamp=try? FileSystem.stamp(url) else { return nil }
        let size=max(64,min(2400,maxPixelSize))
        let text="\(url.path)|\(stamp.size)|\(stamp.modified)|\(stamp.changed)|\(size)"
        let key=SHA256.hash(data:Data(text.utf8)).map{String(format:"%02x",$0)}.joined()
        if let image=memory.object(forKey:key as NSString) { return image }
        if active>=2 { await withCheckedContinuation{waiters.append($0)} } else { active+=1 }
        defer { if waiters.isEmpty { active-=1 } else { waiters.removeFirst().resume() } }
        guard !Task.isCancelled else { return nil }
        let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first?.appendingPathComponent("yo3komi/Thumbnails",isDirectory:true)
        if let cache { try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true) }
        if !pruned,let cache { prune(cache); pruned=true }
        let cachedURL=cache?.appendingPathComponent(key+".jpg")
        if let cachedURL,let image=NSImage(contentsOf:cachedURL) { memory.setObject(image,forKey:key as NSString,cost:size*size*4); return image }
        var cg:CGImage?
        if FileSystem.kind(url) == .video {
            let asset=AVURLAsset(url:url); let generator=AVAssetImageGenerator(asset:asset)
            generator.appliesPreferredTrackTransform=true; generator.maximumSize=CGSize(width:size,height:size)
            cg=try? await generator.image(at:CMTime(seconds:0,preferredTimescale:600)).image
        } else if let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) {
            cg=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageIfAbsent:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:size,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
        }
        guard !Task.isCancelled,let cg else { return nil }
        let image=NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
        memory.setObject(image,forKey:key as NSString,cost:cg.width*cg.height*4)
        if let cachedURL,let dest=CGImageDestinationCreateWithURL(cachedURL as CFURL,"public.jpeg" as CFString,1,nil) { CGImageDestinationAddImage(dest,cg,[kCGImageDestinationLossyCompressionQuality:0.82] as CFDictionary); CGImageDestinationFinalize(dest); writes+=1; if writes % 100 == 0,let cache {prune(cache)} }
        return image
    }
    private func prune(_ root:URL) {
        guard let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey]) else { return }
        let records=files.compactMap{url -> (URL,Int,Date)? in guard let v=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else{return nil};return (url,v.fileSize ?? 0,v.contentModificationDate ?? .distantPast)}.sorted{$0.2<$1.2}
        var total=records.reduce(0){$0+$1.1}
        for (u,size,_) in records where total>2*1024*1024*1024 { try? FileManager.default.removeItem(at:u); total-=size }
    }
}
