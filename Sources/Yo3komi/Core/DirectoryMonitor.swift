import Foundation
import CoreServices

final class DirectoryMonitor {
    private var stream:FSEventStreamRef?
    private let change:() -> Void
    init(urls:[URL],change:@escaping () -> Void) {
        self.change=change
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
        let paths=urls.map(\.path) as CFArray
        stream=FSEventStreamCreate(nil,{_,info,_,_,_,_ in
            guard let info else{return}; let monitor=Unmanaged<DirectoryMonitor>.fromOpaque(info).takeUnretainedValue(); monitor.change()
        },&context,paths,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),1.5,FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents|kFSEventStreamCreateFlagWatchRoot|kFSEventStreamCreateFlagUseCFTypes))
        if let stream { FSEventStreamSetDispatchQueue(stream,DispatchQueue.main); FSEventStreamStart(stream) }
    }
    deinit { if let stream { FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream) } }
}
