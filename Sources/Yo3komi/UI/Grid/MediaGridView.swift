import SwiftUI
import AppKit

/// Virtualised photo grid backed by NSCollectionView. SwiftUI owns the surrounding chrome;
/// this view only renders `model.visibleItems` and forwards user intent back to the model.
struct MediaGridView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var onRequestDateResolution: (MediaItem) -> Void

    func makeCoordinator() -> MediaGridCoordinator { MediaGridCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let layout = UniformGridLayout()
        layout.preferredTileWidth = CGFloat(model.thumbnailSize)

        let collectionView = MediaCollectionView(frame: .zero)
        collectionView.collectionViewLayout = layout
        collectionView.register(MediaTileItem.self, forItemWithIdentifier: MediaTileItem.identifier)
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.coordinator = coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [Theme.grid]
        collectionView.autoresizingMask = [.width]
        collectionView.setAccessibilityLabel("写真と動画の一覧")
        collectionView.setAccessibilityHelp("矢印キーで移動、Spaceでプレビュー、Returnで取り込み対象を切り替え")

        let scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.grid
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false

        coordinator.collectionView = collectionView
        coordinator.layout = layout
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.onRequestDateResolution = onRequestDateResolution
        let filterKey = "\(model.filter.rawValue)|\(model.kindFilter.rawValue)|\(model.dateFilter ?? "")|\(model.sortByDate)"
        coordinator.update(items: model.visibleItems,
                           focusedID: model.focusedItemID,
                           tileWidth: CGFloat(model.thumbnailSize),
                           interactive: !model.isBusy,
                           filterKey: filterKey)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: MediaGridCoordinator) {
        coordinator.cancelAllThumbnails()
    }
}

// MARK: - Collection view

final class MediaCollectionView: NSCollectionView {
    weak var coordinator: MediaGridCoordinator?

    override var acceptsFirstResponder: Bool { true }

    /// The grid is the primary keyboard target when the window first appears.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.firstResponder === window || window.firstResponder == nil else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    /// Edit > Select All (⌘A) marks every selectable item in the current filter for import.
    override func selectAll(_ sender: Any?) {
        coordinator?.setVisibleSelection(true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        if event.clickCount == 2, let indexPath { coordinator?.preview(at: indexPath.item) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point), let coordinator else { return nil }
        coordinator.focus(index: indexPath.item, scroll: false)
        return coordinator.contextMenu(for: indexPath.item)
    }
}

// MARK: - Coordinator

@MainActor
final class MediaGridCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var model: AppModel
    var onRequestDateResolution: ((MediaItem) -> Void)?
    weak var collectionView: MediaCollectionView?
    weak var layout: UniformGridLayout?

    private(set) var items: [MediaItem] = []
    private var ids: [String] = []
    private var indexByID: [String: Int] = [:]
    private var interactive = true
    private var lastFocusedID: String?
    private var lastFilterKey: String?
    private var carryOver: [String: MediaTileItem.ThumbnailSnapshot] = [:]

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Updates from SwiftUI

    func update(items newItems: [MediaItem], focusedID: String?, tileWidth: CGFloat, interactive: Bool, filterKey: String) {
        guard let collectionView else { return }
        layout?.preferredTileWidth = tileWidth
        let interactivityChanged = interactive != self.interactive
        self.interactive = interactive

        let newIDs = newItems.map(\.id)
        let reloaded = newIDs != ids
        if reloaded {
            // Membership or order changed (filter, sort, or dates arriving during the scan).
            for case let tile as MediaTileItem in collectionView.visibleItems() {
                if let id = tile.itemID, let snapshot = tile.thumbnailSnapshot { carryOver[id] = snapshot }
            }
            items = newItems
            ids = newIDs
            indexByID = Dictionary(newIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            collectionView.reloadData()
            // Materialise the new visible items now so they can adopt the carried-over images.
            collectionView.layoutSubtreeIfNeeded()
            carryOver.removeAll(keepingCapacity: true)
            if filterKey != lastFilterKey, let scrollView = collectionView.enclosingScrollView {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            items = newItems
            reconfigureVisible(force: interactivityChanged)
        }
        lastFilterKey = filterKey
        syncFocus(focusedID, reselect: reloaded)
    }

    private func reconfigureVisible(force: Bool) {
        guard let collectionView else { return }
        for case let tile as MediaTileItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: tile), indexPath.item < items.count else { continue }
            tile.configure(items[indexPath.item], interactive: interactive, force: force)
        }
    }

    /// Mirrors `model.focusedItemID` into the collection view selection. Scrolls only when the
    /// focus itself moved (e.g. preview navigation), not when a reload merely restores it.
    private func syncFocus(_ focusedID: String?, reselect: Bool) {
        guard let collectionView else { return }
        let moved = focusedID != lastFocusedID
        guard moved || reselect else { return }
        lastFocusedID = focusedID
        guard let focusedID, let index = indexByID[focusedID] else {
            if !collectionView.selectionIndexPaths.isEmpty { collectionView.deselectAll(nil) }
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        if collectionView.selectionIndexPaths != [indexPath] {
            collectionView.selectionIndexPaths = [indexPath]
        }
        if moved {
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        }
    }

    func cancelAllThumbnails() {
        guard let collectionView else { return }
        for case let tile as MediaTileItem in collectionView.visibleItems() {
            tile.cancelThumbnail()
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: MediaTileItem.identifier, for: indexPath) as! MediaTileItem
        tile.onToggle = { [weak self] id in self?.toggle(id: id) }
        if indexPath.item < items.count {
            let item = items[indexPath.item]
            tile.configure(item, interactive: interactive, carry: carryOver[item.id])
        }
        return tile
    }

    // MARK: Delegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, index < items.count else { return }
        let id = items[index].id
        lastFocusedID = id
        if model.focusedItemID != id { model.focusedItemID = id }
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard collectionView.selectionIndexPaths.isEmpty else { return }
        lastFocusedID = nil
        if model.focusedItemID != nil { model.focusedItemID = nil }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? MediaTileItem)?.cancelThumbnail()
    }

    // MARK: Intent

    func toggle(id: String) {
        guard interactive else { reconfigureVisible(force: true); return }
        model.toggleSelection(id)
        // Re-sync immediately so a refused toggle (e.g. not selectable) snaps back.
        if let index = indexByID[id], let latest = model.items.first(where: { $0.id == id }) {
            items[index] = latest
        }
        reconfigureVisible(force: true)
    }

    func setVisibleSelection(_ selected: Bool) {
        guard interactive else { NSSound.beep(); return }
        model.selectVisible(selected)
    }

    func preview(at index: Int) {
        guard index < items.count else { return }
        model.showPreview(items[index])
    }

    func focus(index: Int, scroll: Bool) {
        guard let collectionView, index >= 0, index < items.count else { return }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectionIndexPaths = [indexPath]
        if scroll { collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge) }
        let id = items[index].id
        lastFocusedID = id
        if model.focusedItemID != id { model.focusedItemID = id }
    }

    private var focusedIndex: Int? {
        if let index = collectionView?.selectionIndexPaths.first?.item, index < items.count { return index }
        if let id = model.focusedItemID { return indexByID[id] }
        return nil
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, !items.isEmpty, let layout else { return false }
        let current = focusedIndex
        func move(_ target: Int) { focus(index: target, scroll: true) }
        switch event.keyCode {
        case 123: move(current.map { layout.index(from: $0, rowDelta: 0, columnDelta: -1) } ?? 0)
        case 124: move(current.map { layout.index(from: $0, rowDelta: 0, columnDelta: 1) } ?? 0)
        case 125: move(current.map { layout.index(from: $0, rowDelta: 1, columnDelta: 0) } ?? 0)
        case 126: move(current.map { layout.index(from: $0, rowDelta: -1, columnDelta: 0) } ?? 0)
        case 115: move(0)
        case 119: move(items.count - 1)
        case 116: move(max(0, (current ?? 0) - layout.itemsPerPage))
        case 121: move(min(items.count - 1, (current ?? 0) + layout.itemsPerPage))
        case 49:
            guard let current else { move(0); return true }
            model.showPreview(items[current])
        case 36, 76:
            guard let current else { return false }
            let item = items[current]
            if item.canSelect { toggle(id: item.id) } else { NSSound.beep() }
        default:
            return false
        }
        return true
    }

    // MARK: Context menu

    func contextMenu(for index: Int) -> NSMenu? {
        guard index < items.count else { return nil }
        let item = items[index]
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "プレビューと詳細", keyEquivalent: " ") { [weak self] in self?.model.showPreview(item) })
        let toggleTitle = item.canSelect && item.isSelected ? "取り込み対象から外す" : "取り込み対象にする"
        let toggleItem = ClosureMenuItem(title: toggleTitle, keyEquivalent: "\r") { [weak self] in self?.toggle(id: item.id) }
        toggleItem.isEnabled = item.canSelect && interactive
        menu.addItem(toggleItem)
        if !item.supplementURLs.isEmpty {
            let supplement = ClosureMenuItem(title: item.supplementSelected ? "付随ファイルの補完をやめる" : "不足している付随ファイルを補完", keyEquivalent: "") { [weak self] in self?.model.toggleSupplement(item.id) }
            supplement.state = item.supplementSelected ? .on : .off
            supplement.isEnabled = interactive
            menu.addItem(supplement)
        }
        if item.status != .imported, item.status != .cardDuplicate {
            let dateItem = ClosureMenuItem(title: "撮影日時を指定…", keyEquivalent: "") { [weak self] in self?.onRequestDateResolution?(item) }
            dateItem.isEnabled = interactive
            menu.addItem(dateItem)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "元ファイルをFinderで表示", keyEquivalent: "") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) })
        if item.duplicateURL != nil || item.destinationURL != nil {
            menu.addItem(ClosureMenuItem(title: item.status == .imported ? "保存先のファイルをFinderで表示" : "保存予定の場所をFinderで表示", keyEquivalent: "") { [weak self] in self?.model.revealItem(item) })
        }
        for entry in menu.items where entry.keyEquivalent == " " || entry.keyEquivalent == "\r" {
            entry.keyEquivalentModifierMask = []
        }
        return menu
    }
}

/// NSMenuItem that runs a closure; keeps context menus free of selector plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
