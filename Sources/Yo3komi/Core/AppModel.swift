import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel:ObservableObject {
    @Published var items:[MediaItem]=[] {didSet{visibleCacheKey=nil}}
    @Published var filter:MediaFilter = .all
    @Published var kindFilter:KindFilter = .all
    @Published var sortByDate=true
    @Published var dateFilter:String?=nil
    @Published var thumbnailSize:Double=180
    @Published var focusedItemID:String?=nil
    @Published var sourceURL:URL?
    @Published var destinationURL:URL?
    @Published var sourceMode:SourceMode = .camera
    @Published var includeDCIM=true
    @Published var includeCLIP=true
    @Published var timeZoneID="Asia/Tokyo"
    @Published var isScanning=false
    @Published var isImporting=false
    @Published var statusMessage="カードを接続してください"
    @Published var scanCompleted=0
    @Published var scanTotal=0
    @Published var warnings:[String]=[]
    @Published var errorMessage:String?=nil
    @Published var progress=ImportProgress()
    @Published var volumes:[VolumeInfo]=[]
    @Published var availableBytes:Int64=0
    @Published var existingFolders:[String]=[]
    @Published var completionMessage:String?=nil
    @Published var appearance="dark"
    @Published var previewItem:MediaItem?=nil
    @Published var sourceConnectionState:ConnectionState = .disconnected
    @Published var destinationConnectionState:ConnectionState = .disconnected
    @Published var isSourceConnected=false
    @Published var isDestinationConnected=false
    @Published var pendingRecoveryCount=0
    private let engine=ImportEngine()
    private var task:Task<Void,Never>?
    private var scheduled:Task<Void,Never>?
    private var observers:[NSObjectProtocol]=[]
    private var monitor:DirectoryMonitor?
    private var accessURLs:[URL]=[]
    private var sourceID:String?
    private var destinationID:String?
    private var validScan=false
    private var scanToken=UUID()
    private var initialized=false
    private var lastSettingsSignature=""
    private var explicitSelections:[String:Bool]=[:]
    private var rememberedDates:[String:Date]=[:]
    private let defaults=UserDefaults.standard
    private var visibleCacheKey:String?
    private var visibleCache:[MediaItem]=[]

    var isBusy:Bool { isScanning || isImporting }
    var visibleItems:[MediaItem] {
        let key="\(filter.rawValue)|\(kindFilter.rawValue)|\(dateFilter ?? "")|\(sortByDate)"
        if visibleCacheKey==key{return visibleCache}
        let visible=items.filter { item in
            (filter == .all || (filter == .new && item.canSelect) || (filter == .imported && item.status == .imported) || (filter == .attention && [.needsDate,.failed].contains(item.status))) &&
            (kindFilter == .all || (kindFilter == .videos && item.isVideo) || (kindFilter == .photos && !item.isVideo)) &&
            (dateFilter == nil || item.dateFolder==dateFilter)
        }
        visibleCache = visible.sorted { a,b in
            if sortByDate, a.captureDate != b.captureDate { return (a.captureDate ?? .distantFuture)<(b.captureDate ?? .distantFuture) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        visibleCacheKey=key
        return visibleCache
    }
    var selectedItems:[MediaItem] { items.filter{($0.canSelect && $0.isSelected) || $0.supplementSelected} }
    var selectedCount:Int { selectedItems.filter(\.isSelected).count }
    var selectedBytes:Int64 {
        let selected=selectedItems
        var bytes=selected.filter(\.isSelected).reduce(Int64(0)){$0+$1.byteCount};var seen=Set<String>()
        for item in selected {
            for r in item.related where item.isSelected || item.supplementURLs.contains(r.url) {
                if seen.insert(r.url.path).inserted {bytes+=r.stamp.size}
            }
        }
        return bytes
    }
    var selectedSidecarCount:Int {
        Set(selectedItems.flatMap{ i in i.related.filter{i.isSelected || i.supplementURLs.contains($0.url)}.map{$0.url.path}}).count
    }
    var selectedPhotoCount:Int { selectedItems.filter{$0.isSelected && !$0.isVideo}.count }
    var selectedVideoCount:Int { selectedItems.filter{$0.isSelected && $0.isVideo}.count }
    var importedCount:Int { items.filter{$0.status == .imported}.count }
    var attentionCount:Int { items.filter{[.needsDate,.failed].contains($0.status)}.count }
    var canImport:Bool { validScan && !isBusy && isSourceConnected && isDestinationConnected && !selectedItems.isEmpty }
    var folderSummaries:[FolderSummary] {
        let grouped=Dictionary(grouping:selectedItems.filter(\.isSelected),by:{$0.dateFolder ?? "日時不明"})
        let all=Set(existingFolders).union(grouped.keys)
        return all.sorted().map { path in
            let entries=grouped[path] ?? []
            return FolderSummary(path:path,count:entries.count,bytes:entries.reduce(0){$0+$1.byteCount},isNew:!existingFolders.contains(path),photos:entries.filter{!$0.isVideo}.count,videos:entries.filter(\.isVideo).count)
        }
    }
    init() {
        sourceURL=URL(fileURLWithPath:defaults.string(forKey:"sourcePath") ?? "/Volumes/Untitled",isDirectory:true)
        destinationURL=URL(fileURLWithPath:defaults.string(forKey:"destinationPath") ?? "/Volumes/CORSAIR/一眼カメラ読み込み",isDirectory:true)
        sourceMode=SourceMode(rawValue:defaults.string(forKey:"sourceMode") ?? "camera") ?? .camera
        if defaults.object(forKey:"includeDCIM") != nil {includeDCIM=defaults.bool(forKey:"includeDCIM");includeCLIP=defaults.bool(forKey:"includeCLIP")}
        timeZoneID=defaults.string(forKey:"timeZoneID") ?? "Asia/Tokyo"; appearance=defaults.string(forKey:"appearance") ?? "dark"
        thumbnailSize=defaults.object(forKey:"thumbnailSize") == nil ? 180 : defaults.double(forKey:"thumbnailSize")
        sourceID=defaults.string(forKey:"sourceIdentity");destinationID=defaults.string(forKey:"destinationIdentity")
        for name in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification,NSWorkspace.didRenameVolumeNotification,NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.mediaChanged()} })
        }
        lastSettingsSignature="\(sourceMode.rawValue)|\(includeDCIM)|\(includeCLIP)|\(timeZoneID)"
        initialized=true
        resolveAccess();refreshVolumes();installMonitor()
        Task { pendingRecoveryCount=await engine.recover(); refresh() }
    }
    func chooseSource() { choose(isSource:true) }
    func chooseDestination() { choose(isSource:false) }
    private func choose(isSource:Bool) {
        guard !isImporting else{return}
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        panel.message=isSource ? "監視するカードまたはフォルダを選択" : "写真・動画の保存先フォルダを選択"
        panel.directoryURL=isSource ? sourceURL : destinationURL
        guard panel.runModal() == .OK,let url=panel.url else{return}
        setLocation(url,isSource:isSource)
    }
    func selectSourceVolume(_ url:URL) {guard !isImporting else{return};setLocation(url,isSource:true)}
    private func setLocation(_ url:URL,isSource:Bool) {
        do {
            var options:URL.BookmarkCreationOptions=[.withSecurityScope]
            if isSource { options.insert(.securityScopeAllowOnlyReadAccess) }
            let bookmark=try url.bookmarkData(options:options,includingResourceValuesForKeys:nil,relativeTo:nil)
            defaults.set(bookmark,forKey:isSource ? "sourceBookmark" : "destinationBookmark")
            let identity=try FileSystem.identity(url)
            if isSource {sourceURL=url;sourceID=identity;defaults.set(identity,forKey:"sourceIdentity")} else {destinationURL=url;destinationID=identity;defaults.set(identity,forKey:"destinationIdentity")}
            defaults.set(url.path,forKey:isSource ? "sourcePath" : "destinationPath")
            explicitSelections.removeAll();rememberedDates.removeAll();resolveAccess();installMonitor();refresh()
        } catch {errorMessage=error.localizedDescription}
    }
    private func resolveAccess() {
        for u in accessURLs {u.stopAccessingSecurityScopedResource()};accessURLs=[]
        var bookmarkErrors=Set<String>()
        for key in ["source","destination"] {
            if let data=defaults.data(forKey:key+"Bookmark") {
                var stale=false
                do {
                    let url=try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
                    if url.startAccessingSecurityScopedResource(){accessURLs.append(url)}
                    if key=="source" {sourceURL=url}else{destinationURL=url}
                    if stale {warnings.append("\(key=="source" ? "取り込み元" : "保存先")を再選択するとアクセス許可を更新できます。")}
                } catch {bookmarkErrors.insert(key);warnings.append("フォルダのアクセス許可を再設定してください。")}
            }
        }
        sourceConnectionState=connectionState(sourceURL,expected:sourceID,bookmarkError:bookmarkErrors.contains("source"),writing:false)
        destinationConnectionState=connectionState(destinationURL,expected:destinationID,bookmarkError:bookmarkErrors.contains("destination"),writing:true)
        isSourceConnected=sourceConnectionState == .connected
        isDestinationConnected=destinationConnectionState == .connected
        availableBytes=destinationURL.map(FileSystem.available) ?? 0
    }
    private func connectionState(_ url:URL?,expected:String?,bookmarkError:Bool,writing:Bool)->ConnectionState {
        guard let url else{return .unconfigured}
        do {
            guard try url.checkResourceIsReachable() else{return .disconnected}
            guard !bookmarkError else{return .error}
            let identity=try FileSystem.identity(url)
            guard expected==nil || expected==identity else{return .error}
            guard FileManager.default.isReadableFile(atPath:url.path),!writing || FileManager.default.isWritableFile(atPath:url.path) else{return .error}
            return .connected
        } catch {
            let e=error as NSError
            if e.domain==NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(e.code){return .disconnected}
            return .error
        }
    }
    func refreshVolumes() {
        volumes=(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:[.volumeNameKey,.volumeIsRemovableKey,.volumeIsInternalKey],options:[.skipHiddenVolumes]) ?? []).compactMap{url in
            guard let v=try? url.resourceValues(forKeys:[.volumeNameKey,.volumeIsRemovableKey,.volumeIsInternalKey]),v.volumeIsInternal != true else{return nil}
            return VolumeInfo(url:url,name:v.volumeName ?? url.lastPathComponent,isRemovable:v.volumeIsRemovable ?? false)
        }
    }
    private func installMonitor() {
        monitor=nil
        let urls=[sourceURL,destinationURL].compactMap{$0}.filter{FileManager.default.fileExists(atPath:$0.path)}
        if !urls.isEmpty { monitor=DirectoryMonitor(urls:urls){[weak self] in Task{@MainActor in self?.directoryChanged()} } }
    }
    private func directoryChanged() {guard !isImporting else{return};validScan=false;debounceRefresh()}
    private func mediaChanged() {
        refreshVolumes();resolveAccess()
        if isImporting {
            if !isSourceConnected || !isDestinationConnected {stop();statusMessage="ストレージが取り外されました。再接続して再読み込みしてください。"}
            return
        }
        installMonitor();debounceRefresh()
    }
    private func debounceRefresh() {
        scheduled?.cancel();scheduled=Task {try? await Task.sleep(nanoseconds:1_200_000_000);guard !Task.isCancelled else{return};refresh()}
    }
    func settingsChanged() {
        guard initialized,!isImporting else{return}
        defaults.set(sourceMode.rawValue,forKey:"sourceMode");defaults.set(includeDCIM,forKey:"includeDCIM");defaults.set(includeCLIP,forKey:"includeCLIP")
        defaults.set(timeZoneID,forKey:"timeZoneID");defaults.set(appearance,forKey:"appearance");defaults.set(thumbnailSize,forKey:"thumbnailSize")
        let signature="\(sourceMode.rawValue)|\(includeDCIM)|\(includeCLIP)|\(timeZoneID)"
        if signature != lastSettingsSignature {lastSettingsSignature=signature;validScan=false;debounceRefresh()}
    }
    func refresh(force:Bool=false) {
        guard !isImporting else{return}
        task?.cancel();scanToken=UUID();let token=scanToken
        resolveAccess();validScan=false;completionMessage=nil
        guard isSourceConnected,let source=sourceURL else{isScanning=false;items=[];statusMessage="取り込み元を接続、またはフォルダを選択してください";return}
        guard isDestinationConnected,let destination=destinationURL else{isScanning=false;statusMessage="保存先を接続、またはフォルダを選択してください";return}
        guard TimeZone(identifier:timeZoneID) != nil else{errorMessage="撮影地のタイムゾーンが不正です。";return}
        isScanning=true;scanCompleted=0;scanTotal=0;warnings=[];errorMessage=nil
        let request=ScanRequest(source:source,destination:destination,mode:sourceMode,dcim:includeDCIM,clip:includeCLIP,timeZone:timeZoneID,force:force)
        task=Task.detached(priority:.userInitiated){[weak self,engine] in
            guard let owner=self else{return}
            do {
                let result=try await engine.scan(request){event in await owner.apply(event,token:token)}
                guard !Task.isCancelled else{return}
                await owner.finishScan(result,token:token)
            } catch is CancellationError {await owner.cancelledScan(token:token)}
            catch {await owner.failScan(error.localizedDescription,token:token)}
        }
    }
    private func apply(_ event:ScanUpdate,token:UUID) {
        guard token==scanToken else{return}
        if let loaded=event.items {items=loaded}
        if !event.changed.isEmpty {
            let updates=Dictionary(uniqueKeysWithValues:event.changed.map{($0.id,$0)})
            items=items.map{updates[$0.id] ?? $0}
        }
        scanCompleted=event.completed;scanTotal=event.total;statusMessage=event.message
    }
    private func finishScan(_ result:ScanResult,token:UUID) {
        guard token==scanToken else{return}
        items=result.items;warnings=result.warnings;existingFolders=result.existingFolders;sourceID=result.sourceIdentity;destinationID=result.destinationIdentity
        defaults.set(sourceID,forKey:"sourceIdentity");defaults.set(destinationID,forKey:"destinationIdentity")
        for i in items.indices {
            if let date=rememberedDates[items[i].id],(items[i].status == .needsDate || items[i].status == .new) {applyDate(at:i,date:date)}
            if let selected=explicitSelections[items[i].id],items[i].canSelect {items[i].isSelected=selected}
        }
        isScanning=false;validScan=true;availableBytes=destinationURL.map(FileSystem.available) ?? 0
        statusMessage="\(items.count)件を確認・\(importedCount)件は取り込み済み"
        if sourceURL != nil,defaults.data(forKey:"sourceBookmark")==nil {saveDefaultBookmark(sourceURL!,key:"source",readOnly:true)}
        if destinationURL != nil,defaults.data(forKey:"destinationBookmark")==nil {saveDefaultBookmark(destinationURL!,key:"destination",readOnly:false)}
    }
    private func saveDefaultBookmark(_ url:URL,key:String,readOnly:Bool) {
        var options:URL.BookmarkCreationOptions=[.withSecurityScope];if readOnly{options.insert(.securityScopeAllowOnlyReadAccess)}
        if let data=try? url.bookmarkData(options:options,includingResourceValuesForKeys:nil,relativeTo:nil){defaults.set(data,forKey:key+"Bookmark")}
    }
    private func cancelledScan(token:UUID){guard token==scanToken else{return};isScanning=false;statusMessage="走査を停止しました"}
    private func failScan(_ text:String,token:UUID){guard token==scanToken else{return};isScanning=false;statusMessage="照合を完了できませんでした";errorMessage=text}
    func toggleSelection(_ id:String) {
        guard !isBusy,let i=items.firstIndex(where:{$0.id==id}),items[i].canSelect else{return}
        items[i].isSelected.toggle();explicitSelections[id]=items[i].isSelected
    }
    func selectVisible(_ selected:Bool){guard !isBusy else{return};let ids=Set(visibleItems.filter(\.canSelect).map(\.id));for i in items.indices where ids.contains(items[i].id){items[i].isSelected=selected;explicitSelections[items[i].id]=selected}}
    func toggleSupplement(_ id:String){guard !isBusy,let i=items.firstIndex(where:{$0.id==id}),!items[i].supplementURLs.isEmpty else{return};items[i].supplementSelected.toggle()}
    func resolveDate(_ id:String,date:Date){guard !isBusy,let i=items.firstIndex(where:{$0.id==id}),items[i].status != .imported,items[i].status != .cardDuplicate else{return};rememberedDates[id]=date;applyDate(at:i,date:date)}
    private func applyDate(at i:Int,date:Date){items[i].captureDate=date;items[i].dateFolder=MetadataReader.folder(for:date,zone:TimeZone(identifier:timeZoneID) ?? .current);items[i].dateEvidence="ユーザー指定日付";items[i].status = .new;items[i].isSelected=explicitSelections[items[i].id] ?? true;items[i].message="";if let root=destinationURL{items[i].destinationURL=root.appendingPathComponent(items[i].dateFolder!).appendingPathComponent(items[i].name)}}
    func useModificationDate(_ id:String){guard let item=items.first(where:{$0.id==id}) else{return};resolveDate(id,date:Date(timeIntervalSince1970:item.stamp.modified))}
    func startImport() {
        guard canImport,let source=sourceURL,let destination=destinationURL else{return}
        scheduled?.cancel();monitor=nil;isImporting=true;completionMessage=nil;errorMessage=nil
        let plan=selectedItems;progress=ImportProgress(phase:"保存先を再確認中",total:plan.count,totalBytes:selectedBytes)
        task=Task.detached(priority:.userInitiated){[weak self,engine] in
            guard let owner=self else{return}
            do {
                try await engine.runImport(items:plan,source:source,destination:destination,progress:{p in await owner.setProgress(p)},outcome:{o in await owner.applyOutcome(o)})
                await owner.finishImport(nil,cancelled:false)
            } catch is CancellationError {await owner.finishImport(nil,cancelled:true)}
            catch {await owner.finishImport(error.localizedDescription,cancelled:false)}
        }
    }
    private func setProgress(_ p:ImportProgress){progress=p;statusMessage=p.phase;if let i=items.firstIndex(where:{$0.id==p.currentID}),items[i].status != .imported{let next:ItemStatus=p.phase=="検証中" ? .verifying : .copying;if items[i].status != next{items[i].status=next}}}
    private func applyOutcome(_ result:ImportOutcome){guard let i=items.firstIndex(where:{$0.id==result.id}) else{return};items[i].message=result.message;if let u=result.destination{items[i].destinationURL=u;items[i].duplicateURL=u;items[i].status = .imported;items[i].isSelected=false;explicitSelections[result.id]=nil}else{items[i].status = .failed};items[i].supplementSelected=false;if result.success{items[i].supplementURLs=[]}}
    private func finishImport(_ error:String?,cancelled:Bool){for i in items.indices where items[i].status == .copying || items[i].status == .verifying{items[i].status = .failed;items[i].isSelected=false;items[i].message=error ?? "処理を停止しました。再読み込みしてください。"};isImporting=false;validScan=false;availableBytes=destinationURL.map(FileSystem.available) ?? 0;installMonitor();if let error{errorMessage=error;statusMessage="取り込みを一時停止しました"}else if cancelled{statusMessage="取り込みを停止しました。再読み込みして続けられます。"}else{let failed=items.filter{!$0.message.isEmpty && $0.message.contains("失敗")}.count;completionMessage="\(progress.completed)件の処理が完了しました"+(failed>0 ? "（付随ファイル失敗\(failed)件）" : "");statusMessage=completionMessage!};Task{pendingRecoveryCount=await engine.recover()}}
    func stop(){scheduled?.cancel();task?.cancel()}
    func clearRecovery(){guard !isBusy else{return};Task{do{try await engine.clearRecovery();pendingRecoveryCount=await engine.recover()}catch{errorMessage=error.localizedDescription}}}
    func revealDestination(){if let destinationURL{NSWorkspace.shared.open(destinationURL)}}
    func revealItem(_ item:MediaItem){let candidate=item.duplicateURL ?? item.destinationURL ?? item.url;NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath:candidate.path) ? candidate : item.url])}
    func showPreview(_ item:MediaItem){previewItem=item;focusedItemID=item.id}
    func dismissError(){errorMessage=nil}
}
