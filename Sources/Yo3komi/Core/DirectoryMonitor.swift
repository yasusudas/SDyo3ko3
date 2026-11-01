import Foundation
import CoreServices

/// FSEvents are hints, not instructions to discard a completed scan.
struct DirectoryWatch {
    let root: URL
    /// nil watches the whole tree; camera mode watches just the enabled camera trees.
    let subdirectories: [String]?

    init(root: URL, subdirectories: [String]?) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.subdirectories = subdirectories
    }

    func contains(_ path: String, directory: Bool) -> Bool {
        let rootPath = root.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
        guard !relative.contains(where: { $0.hasPrefix(".") }) else { return false }
        guard let subdirectories else { return true }
        return subdirectories.contains { subdirectory in
            let target = root.appendingPathComponent(subdirectory).standardizedFileURL.path
            return path == target || path.hasPrefix(target + "/") || (directory && target.hasPrefix(path + "/"))
        }
    }
}

final class DirectoryMonitor {
    private var stream: FSEventStreamRef?
    private let watches: [DirectoryWatch]
    private let change: () -> Void

    static func needsReconciliation(path: String, flags: FSEventStreamEventFlags, watches: [DirectoryWatch]) -> Bool {
        let uncertain = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                               kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped |
                               kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        // Loss/root events can refer to an ancestor outside the watched trees.
        if flags & uncertain != 0 { return true }
        let directory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard watches.contains(where: { $0.contains(path, directory: directory) }) else { return false }
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        if directory { return flags & structural != 0 }
        // Finder/Spotlight xattrs, ownership and inode metadata do not change media bytes.
        let content = structural | UInt32(kFSEventStreamEventFlagItemModified)
        return flags & content != 0 && FileSystem.kind(URL(fileURLWithPath: path)) != nil
    }

    init(watches: [DirectoryWatch], change: @escaping () -> Void) {
        self.watches = watches
        self.change = change
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<DirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            if (0..<count).contains(where: { DirectoryMonitor.needsReconciliation(path: paths[$0], flags: flags[$0], watches: monitor.watches) }) {
                monitor.change()
            }
        }, &context, watches.map { $0.root.path } as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot |
                                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf))
        if let stream { FSEventStreamSetDispatchQueue(stream, DispatchQueue.main); FSEventStreamStart(stream) }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
