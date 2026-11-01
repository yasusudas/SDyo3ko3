import XCTest
@testable import Yo3komi

final class DateSelectionTests: XCTestCase {
    @MainActor private func model() throws -> AppModel {
        let suite = "yo3komi-date-selection-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("/nonexistent-yo3komi-" + UUID().uuidString, forKey: "sourcePath")
        defaults.set("/nonexistent-yo3komi-" + UUID().uuidString, forKey: "destinationPath")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(defaults: defaults, startsAutomatically: false)
    }

    private func item(_ name: String, date: String? = "2026/11-01", kind: MediaKind = .raw,
                      status: ItemStatus = .new, selected: Bool = false) -> MediaItem {
        var value = MediaItem(url: URL(fileURLWithPath: "/fixture/" + name), relativePath: name, kind: kind,
                              stamp: FileStamp(size: 100, modified: 0, changed: 0, fileID: name))
        value.dateFolder = date
        value.destinationURL = date.map { URL(fileURLWithPath: "/archive/" + $0 + "/" + name) }
        value.status = status; value.isSelected = selected
        return value
    }

    @MainActor func testDateSelectionIncludesHiddenPhotoAndVideoButSkipsDuplicates() async throws {
        let m = try model(); defer { m.stop() }
        m.items = [item("photo.ARW"), item("video.MP4", kind: .video),
                   item("retry.JPG", kind: .photo, status: .failed),
                   item("imported.ARW", status: .imported), item("duplicate.ARW", status: .cardDuplicate),
                   item("unknown.ARW", date: nil, status: .needsDate), item("other.ARW", date: "2026/11-02")]
        m.filter = .imported; m.kindFilter = .photos; m.dateFilter = "2026/11-02"
        m.selectDate("2026/11-01", selected: true)
        XCTAssertEqual(m.items.filter(\.isSelected).map(\.name), ["photo.ARW", "video.MP4", "retry.JPG"])
        XCTAssertEqual(m.dateSelections["2026/11-01"], DateSelectionSummary(total: 3, selected: 3))
        XCTAssertEqual(m.selectedBytes, 300)
        XCTAssertEqual(m.filter, .imported)
        XCTAssertEqual(m.kindFilter, .photos)
        XCTAssertEqual(m.dateFilter, "2026/11-02")
    }

    @MainActor func testDeselectKeepsDateAndYearAvailableForReselection() async throws {
        let m = try model(); defer { m.stop() }
        m.items = [item("one.ARW", selected: true), item("two.MP4", kind: .video, selected: true)]
        m.selectDate("2026/11-01", selected: false)
        XCTAssertEqual(m.selectedCount, 0)
        let day = try XCTUnwrap(m.folderSummaries.first { $0.path == "2026/11-01" })
        XCTAssertEqual(day.count, 0)
        XCTAssertTrue(day.isNew)
        let years = DateTreeYear.build(m.folderSummaries, selectableDates: Set(m.dateSelections.keys))
        XCTAssertEqual(years.count, 1)
        XCTAssertTrue(years[0].hasSelectableItems)
        XCTAssertEqual(years[0].days.map(\.path), ["2026/11-01"])
        m.selectDate("2026/11-01", selected: true)
        XCTAssertEqual(m.selectedCount, 2)
        XCTAssertEqual(m.folderSummaries.first?.count, 2)
    }

    @MainActor func testPartialSelectionUpdatesAfterIndividualAndBulkActions() async throws {
        let m = try model(); defer { m.stop() }
        m.items = [item("one.ARW", selected: true), item("two.ARW")]
        XCTAssertTrue(try XCTUnwrap(m.dateSelections["2026/11-01"]).isPartiallySelected)
        m.selectDate("2026/11-01", selected: true)
        XCTAssertTrue(try XCTUnwrap(m.dateSelections["2026/11-01"]).isAllSelected)
        m.toggleSelection(m.items[0].id)
        XCTAssertTrue(try XCTUnwrap(m.dateSelections["2026/11-01"]).isPartiallySelected)
        m.selectDate("2026/11-01", selected: false)
        let empty = try XCTUnwrap(m.dateSelections["2026/11-01"])
        XCTAssertFalse(empty.isAllSelected)
        XCTAssertFalse(empty.isPartiallySelected)
    }

    @MainActor func testBulkSelectionIsDisabledDuringWork() async throws {
        let m = try model(); defer { m.stop() }
        m.items = [item("one.ARW")]
        m.isScanning = true; m.selectDate("2026/11-01", selected: true); m.isScanning = false
        XCTAssertFalse(m.items[0].isSelected)
        m.isImporting = true; m.selectDate("2026/11-01", selected: true); m.isImporting = false
        XCTAssertFalse(m.items[0].isSelected)
        m.isManagingHistory = true; m.selectDate("2026/11-01", selected: true); m.isManagingHistory = false
        XCTAssertFalse(m.items[0].isSelected)
    }

    @MainActor func testArchiveOnlyDateHasNoSelectionControl() async throws {
        let m = try model(); defer { m.stop() }
        m.existingFolders = ["2024/01-01"]
        m.items = [item("already.ARW", date: "2024/01-01", status: .imported)]
        m.selectDate("2024/01-01", selected: true)
        XCTAssertTrue(m.dateSelections.isEmpty)
        XCTAssertFalse(m.items[0].isSelected)
        XCTAssertEqual(m.folderSummaries.map(\.path), ["2024/01-01"])
    }
}
