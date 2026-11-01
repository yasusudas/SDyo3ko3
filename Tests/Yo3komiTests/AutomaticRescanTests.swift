import XCTest
import CoreServices
import AppKit
@testable import Yo3komi

final class AutomaticRescanTests: XCTestCase {
    private let card = URL(fileURLWithPath: "/Volumes/TestCard", isDirectory: true)
    private let archive = URL(fileURLWithPath: "/Volumes/TestArchive/Photos", isDirectory: true)

    private var watches: [DirectoryWatch] {
        [DirectoryWatch(root: card, subdirectories: ["DCIM", "PRIVATE/M4ROOT/CLIP"]),
         DirectoryWatch(root: archive, subdirectories: nil)]
    }

    private func requiresCheck(_ path: String, _ flags: Int) -> Bool {
        DirectoryMonitor.needsReconciliation(path: path, flags: UInt32(flags), watches: watches)
    }

    func testManagementFilesAndPureMetadataDoNotRequestReconciliation() {
        let modified = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile
        for path in ["/Volumes/TestCard/.DS_Store", "/Volumes/TestCard/DCIM/.DS_Store",
                     "/Volumes/TestCard/DCIM/._DSC0001.ARW",
                     "/Volumes/TestArchive/Photos/.Spotlight-V100/cache.jpg",
                     "/Volumes/TestArchive/Photos/.Trashes/2026/11-01/DSC0001.ARW",
                     "/Volumes/TestCard/DCIM/note.txt"] {
            XCTAssertFalse(requiresCheck(path, modified), path)
        }
        for flag in [kFSEventStreamEventFlagItemInodeMetaMod, kFSEventStreamEventFlagItemFinderInfoMod,
                     kFSEventStreamEventFlagItemChangeOwner, kFSEventStreamEventFlagItemXattrMod] {
            XCTAssertFalse(requiresCheck("/Volumes/TestCard/DCIM/DSC0001.ARW", flag | kFSEventStreamEventFlagItemIsFile))
        }
    }

    func testRealMediaAndSidecarChangesRequestReconciliation() {
        for flag in [kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemRemoved,
                     kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemModified] {
            for path in ["/Volumes/TestCard/DCIM/100MEDIA/DSC0001.ARW",
                         "/Volumes/TestCard/PRIVATE/M4ROOT/CLIP/C0001.MP4",
                         "/Volumes/TestCard/PRIVATE/M4ROOT/CLIP/C0001M01.XML",
                         "/Volumes/TestArchive/Photos/2026/11-01/DSC0001.xmp"] {
                XCTAssertTrue(requiresCheck(path, flag | kFSEventStreamEventFlagItemIsFile), path)
            }
        }
    }

    func testCameraScopeAndDirectoryStructure() {
        let created = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile
        XCTAssertFalse(requiresCheck("/Volumes/TestCard/OTHER/preview.jpg", created))
        XCTAssertFalse(requiresCheck("/Volumes/TestCard2/DCIM/photo.jpg", created))
        XCTAssertFalse(requiresCheck("/Volumes/Other/Photos/photo.jpg", created))
        XCTAssertTrue(requiresCheck("/Volumes/TestCard/PRIVATE", kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir))
        XCTAssertTrue(requiresCheck("/Volumes/TestArchive/Photos/2026/11-02", kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir))
        XCTAssertFalse(requiresCheck("/Volumes/TestArchive/Photos/2026", kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir))
        let dcimOnly = [DirectoryWatch(root: card, subdirectories: ["DCIM"])]
        XCTAssertFalse(DirectoryMonitor.needsReconciliation(path: "/Volumes/TestCard/PRIVATE/M4ROOT/CLIP/C0001.MP4", flags: UInt32(created), watches: dcimOnly))
    }

    func testLostEventsAndRootChangesAreNeverDiscarded() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            XCTAssertTrue(requiresCheck("/Volumes", flag))
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        var request: ScanRequest {
            ScanRequest(source: source, destination: destination, mode: .folder, dcim: true,
                        clip: true, timeZone: "Asia/Tokyo", force: false)
        }
        func file(_ relative: String, destination: Bool = false, contents: String = "fixture bytes") throws -> URL {
            let url = (destination ? self.destination : source).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yo3komi-rescan-" + UUID().uuidString, isDirectory: true)
        let value = Fixture(root: root, source: root.appendingPathComponent("source"), destination: root.appendingPathComponent("archive"))
        try FileManager.default.createDirectory(at: value.source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: value.destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return value
    }

    func testUnchangedSnapshotAndUnrelatedFilesRemainUnchanged() throws {
        let f = try fixture()
        _ = try f.file("DCIM/photo.ARW")
        _ = try f.file("2026/11-01/photo.ARW", destination: true)
        let baseline = try ScanObservation.capture(f.request)
        XCTAssertEqual(try ScanObservation.capture(f.request), baseline)
        _ = try f.file("DCIM/.DS_Store")
        _ = try f.file(".Spotlight-V100/cache.jpg", destination: true)
        _ = try f.file("notes.txt", destination: true)
        XCTAssertEqual(try ScanObservation.capture(f.request), baseline)
    }

    func testSourceAdditionRemovalRenameAndSidecarChangeAreDetected() throws {
        let f = try fixture()
        let photo = try f.file("photo.ARW")
        let baseline = try ScanObservation.capture(f.request)
        let extra = try f.file("extra.JPG")
        XCTAssertNotEqual(try ScanObservation.capture(f.request), baseline)
        try FileManager.default.removeItem(at: extra)
        XCTAssertEqual(try ScanObservation.capture(f.request), baseline)
        let renamed = f.source.appendingPathComponent("renamed.ARW")
        try FileManager.default.moveItem(at: photo, to: renamed)
        XCTAssertNotEqual(try ScanObservation.capture(f.request), baseline)
        let renamedBaseline = try ScanObservation.capture(f.request)
        _ = try f.file("renamed.xmp")
        XCTAssertNotEqual(try ScanObservation.capture(f.request), renamedBaseline)
        try FileManager.default.removeItem(at: renamed)
        XCTAssertNotEqual(try ScanObservation.capture(f.request), renamedBaseline)
    }

    func testDestinationChangesAndEmptyDateFoldersAreDetected() throws {
        let f = try fixture()
        let baseline = try ScanObservation.capture(f.request)
        let dateFolder = f.destination.appendingPathComponent("2026/11-01")
        try FileManager.default.createDirectory(at: dateFolder, withIntermediateDirectories: true)
        let withFolder = try ScanObservation.capture(f.request)
        XCTAssertNotEqual(withFolder, baseline)
        let media = try f.file("2026/11-01/photo.JPG", destination: true)
        let withPhoto = try ScanObservation.capture(f.request)
        XCTAssertNotEqual(withPhoto, withFolder)
        _ = try f.file("2026/11-01/photo.JPG", destination: true, contents: "changed bytes")
        XCTAssertNotEqual(try ScanObservation.capture(f.request), withPhoto)
        try FileManager.default.removeItem(at: media)
        XCTAssertEqual(try ScanObservation.capture(f.request), withFolder)
    }

    func testCameraScopeAndSettingsArePartOfSnapshot() throws {
        let f = try fixture()
        _ = try f.file("DCIM/photo.ARW")
        var request = f.request
        request.mode = .camera; request.clip = false
        let baseline = try ScanObservation.capture(request)
        _ = try f.file("OTHER/photo.JPG")
        _ = try f.file("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        XCTAssertEqual(try ScanObservation.capture(request), baseline)
        request.clip = true
        XCTAssertFalse(baseline.matchesRequest(request))
        XCTAssertNotEqual(try ScanObservation.capture(request), baseline)
        request = f.request; request.timeZone = "UTC"
        XCTAssertFalse(baseline.matchesRequest(request))
    }

    func testCompleteFileStampAndIdentityRemainStrict() throws {
        let f = try fixture()
        let media = try f.file("photo.ARW")
        let baseline = try ScanObservation.capture(f.request)
        var changedStamp = try FileSystem.stamp(media)
        changedStamp.changed += 1
        let differentCTime = ScanObservation(request: f.request, sourceIdentity: baseline.sourceIdentity,
                                             destinationIdentity: baseline.destinationIdentity,
                                             sourceFiles: [media.path: changedStamp], destinationFiles: [:], folders: [])
        XCTAssertNotEqual(baseline, differentCTime)
        changedStamp = try FileSystem.stamp(media); changedStamp.fileID += "-replacement"
        let differentInode = ScanObservation(request: f.request, sourceIdentity: baseline.sourceIdentity,
                                             destinationIdentity: baseline.destinationIdentity,
                                             sourceFiles: [media.path: changedStamp], destinationFiles: [:], folders: [])
        XCTAssertNotEqual(baseline, differentInode)
        let differentVolume = ScanObservation(request: f.request, sourceIdentity: "replacement-volume",
                                              destinationIdentity: baseline.destinationIdentity,
                                              sourceFiles: baseline.sourceFiles, destinationFiles: [:], folders: [])
        XCTAssertNotEqual(baseline, differentVolume)
        try FileManager.default.removeItem(at: f.source)
        XCTAssertThrowsError(try ScanObservation.capture(f.request))
    }

    @MainActor
    func testWakeAndUnrelatedVolumesPreserveIdleAndActiveScan() async throws {
        let suite = "yo3komi-rescan-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults.set(absent.appendingPathComponent("source").path, forKey: "sourcePath")
        defaults.set(absent.appendingPathComponent("destination").path, forKey: "destinationPath")
        let model = AppModel(defaults: defaults, startsAutomatically: false)
        let center = NSWorkspace.shared.notificationCenter
        let unrelated = [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/Volumes/UnrelatedTimeMachine")]
        model.statusMessage = "保持する走査結果"
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: unrelated)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: unrelated)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.statusMessage, "保持する走査結果")
        XCTAssertTrue(model.items.isEmpty)

        model.isScanning = true
        model.scanCompleted = 42; model.scanTotal = 100
        model.statusMessage = "進行中の走査を保持"
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.didMountNotification, object: nil, userInfo: unrelated)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil, userInfo: unrelated)
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.scanCompleted, 42)
        XCTAssertEqual(model.scanTotal, 100)
        XCTAssertEqual(model.statusMessage, "進行中の走査を保持")
        model.isScanning = false
        model.stop()
    }

    @MainActor
    func testNativeFSEventsIgnoreNoiseButDeliverCameraMediaChanges() async throws {
        let f = try fixture()
        let dcim = f.source.appendingPathComponent("DCIM")
        let other = f.source.appendingPathComponent("OTHER")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var callbacks = 0
        let monitor = DirectoryMonitor(watches: [DirectoryWatch(root: f.source, subdirectories: ["DCIM"])]) {
            callbacks += 1
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        callbacks = 0
        _ = try f.file("DCIM/.DS_Store")
        _ = try f.file("DCIM/self-created.JPG")
        func touch(_ urls: [URL]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
            process.arguments = urls.map(\.path)
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try touch([dcim.appendingPathComponent(".DS_Store"), other.appendingPathComponent("outside.JPG")])
        try await Task.sleep(nanoseconds: 2_800_000_000)
        XCTAssertEqual(callbacks, 0, "Management files, unrelated camera trees and this process's writes must not trigger scans")
        try touch([dcim.appendingPathComponent("external-created.JPG")])
        for _ in 0..<60 where callbacks == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertGreaterThan(callbacks, 0, "Real camera media additions must still be delivered")
        withExtendedLifetime(monitor) {}
    }

    @MainActor
    func testRealChangesWaitForActiveScanAndStopDoesNotReviveIt() async throws {
        let f = try fixture()
        let suite = "yo3komi-rescan-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(f.source.path, forKey: "sourcePath")
        // Even a broken automatic restart must fail before opening the real history store.
        defaults.set(f.root.appendingPathComponent("unavailable-destination").path, forKey: "destinationPath")
        defaults.set(SourceMode.folder.rawValue, forKey: "sourceMode")
        let model = AppModel(defaults: defaults, startsAutomatically: false)
        model.isScanning = true
        model.scanCompleted = 42; model.scanTotal = 100
        model.statusMessage = "進行中の走査を保持"
        try await Task.sleep(nanoseconds: 2_000_000_000)
        var publishedChanges = 0
        let observation = model.objectWillChange.sink { publishedChanges += 1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [f.source.appendingPathComponent("external-created.JPG").path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try await Task.sleep(nanoseconds: 3_300_000_000)
        XCTAssertGreaterThan(publishedChanges, 0, "The real event must have reached AppModel")
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.scanCompleted, 42)
        XCTAssertEqual(model.scanTotal, 100)
        XCTAssertEqual(model.statusMessage, "進行中の走査を保持")
        model.stop()
        model.isScanning = false
        model.statusMessage = "ユーザーによる停止"
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.statusMessage, "ユーザーによる停止")
        XCTAssertEqual(model.scanCompleted, 42)
        withExtendedLifetime(observation) {}
    }
}
