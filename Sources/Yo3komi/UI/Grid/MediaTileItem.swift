import AppKit

/// Collection view item that owns exactly one in-flight thumbnail request. Requests start only
/// when the collection view materialises the item (visible rect plus AppKit's small prepared
/// margin) and are cancelled on reuse or when the item leaves the screen.
final class MediaTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MediaTileItem")

    var tile: MediaTileView { view as! MediaTileView }
    var onToggle: ((String) -> Void)?
    private(set) var itemID: String?
    private var current: MediaItem?
    private var signature: Signature?
    private var thumbnailTask: Task<Void, Never>?
    private var inflightKey: String?
    private var loadedKey: String?
    private var loadedPixels = 0

    override func loadView() {
        let tile = MediaTileView(frame: NSRect(x: 0, y: 0, width: 180, height: 160))
        tile.checkbox.target = self
        tile.checkbox.action = #selector(checkboxClicked)
        view = tile
    }

    override var isSelected: Bool {
        didSet { tile.isFocused = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        itemID = nil
        current = nil
        signature = nil
        loadedKey = nil
        loadedPixels = 0
        tile.isFocused = false
        tile.setThumbnail(.loading)
    }

    @objc private func checkboxClicked() {
        if let itemID { onToggle?(itemID) }
    }

    /// Image already on screen for an item, handed to whichever item instance shows it after a reload.
    struct ThumbnailSnapshot {
        var key: String
        var pixels: Int
        var image: NSImage
    }

    var thumbnailSnapshot: ThumbnailSnapshot? {
        guard let loadedKey, let image = tile.imageView.image else { return nil }
        return ThumbnailSnapshot(key: loadedKey, pixels: loadedPixels, image: image)
    }

    /// `force` re-applies even when nothing changed, e.g. after a refused checkbox click.
    /// `carry` lets a recycled item show the previous image immediately instead of flashing empty.
    func configure(_ item: MediaItem, interactive: Bool, force: Bool = false, carry: ThumbnailSnapshot? = nil) {
        let isNewItem = itemID != item.id
        itemID = item.id
        current = item
        let next = Signature(item, interactive: interactive)
        if force || next != signature {
            signature = next
            tile.apply(Self.content(for: item, interactive: interactive))
        }
        if isNewItem {
            loadedKey = nil
            loadedPixels = 0
            if let carry, carry.key.hasPrefix(Self.keyPrefix(item)) {
                tile.setThumbnail(.image(carry.image))
                loadedKey = carry.key
                loadedPixels = carry.pixels
            }
        }
        requestThumbnailIfNeeded()
    }

    private static func keyPrefix(_ item: MediaItem) -> String {
        "\(item.id)|\(item.stamp.size)|\(item.stamp.modified)|"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        requestThumbnailIfNeeded()
    }

    func cancelThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        inflightKey = nil
    }

    // MARK: Thumbnails

    /// Coarse buckets keep the thumbnail cache effective while the size slider moves.
    private static let buckets = [256, 384, 512, 768, 1024]

    private var desiredPixels: Int {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let needed = Int((view.bounds.width - 12) * scale)
        return Self.buckets.first { $0 >= needed } ?? Self.buckets.last!
    }

    private func requestThumbnailIfNeeded() {
        guard let item = current, view.bounds.width > 20 else { return }
        let pixels = desiredPixels
        let key = Self.keyPrefix(item) + "\(pixels)"
        if key == inflightKey { return }
        // A sharper image of the same file is never replaced by a smaller one.
        if let loadedKey, loadedKey.hasPrefix(Self.keyPrefix(item)), pixels <= loadedPixels { return }
        thumbnailTask?.cancel()
        inflightKey = key
        if !tile.hasThumbnailImage { tile.setThumbnail(.loading) }
        let url = item.url
        let ext = item.fileExtension
        thumbnailTask = Task { [weak self] in
            let image = await ThumbnailService.shared.thumbnail(for: url, maxPixelSize: pixels)
            guard !Task.isCancelled, let self, self.inflightKey == key else { return }
            self.inflightKey = nil
            self.thumbnailTask = nil
            self.loadedKey = key
            self.loadedPixels = pixels
            if let image {
                self.tile.setThumbnail(.image(image))
            } else if !self.tile.hasThumbnailImage {
                self.tile.setThumbnail(.unavailable(fileExtension: ext))
            }
        }
    }

    // MARK: Presentation

    private struct Signature: Equatable {
        var id: String
        var status: ItemStatus
        var checked: Bool
        var enabled: Bool
        var related: Int
        var supplements: Int
        var supplementSelected: Bool
        var duration: Double?
        var message: String

        init(_ item: MediaItem, interactive: Bool) {
            id = item.id
            status = item.status
            checked = item.canSelect && item.isSelected
            enabled = item.canSelect && interactive
            related = item.related.count
            supplements = item.supplementURLs.count
            supplementSelected = item.supplementSelected
            duration = item.duration
            message = item.message
        }
    }

    static func content(for item: MediaItem, interactive: Bool) -> MediaTileView.Content {
        let style = StatusStyle(item)
        var status = style.label
        if !item.supplementURLs.isEmpty {
            status += item.supplementSelected ? " · 付随補完あり" : " · 付随\(item.supplementURLs.count)件不足"
        }
        if item.status == .failed, !item.message.isEmpty { status = "失敗: " + item.message }
        let checked = item.canSelect && item.isSelected
        let help = selectionHelp(item, interactive: interactive)
        var summary = [item.name, UIFormat.kindLabel(item), style.label]
        if let duration = UIFormat.duration(item.duration) { summary.append("再生時間 \(duration)") }
        summary.append(checked ? "取り込み対象" : "取り込み対象外")
        if !item.canSelect { summary.append(help) }
        if !item.related.isEmpty { summary.append("付随ファイル\(item.related.count)件") }
        return MediaTileView.Content(
            name: item.name,
            formatText: item.fileExtension.isEmpty ? "?" : item.fileExtension,
            isRaw: item.kind == .raw,
            duration: item.isVideo ? UIFormat.duration(item.duration) : nil,
            sidecarCount: item.related.count,
            isChecked: checked,
            canSelect: item.canSelect && interactive,
            style: style,
            statusText: status,
            accessibilitySummary: summary.joined(separator: "、"),
            checkboxHelp: help)
    }

    static func selectionHelp(_ item: MediaItem, interactive: Bool) -> String {
        if item.canSelect {
            if !interactive { return "処理中は選択を変更できません" }
            return item.isSelected ? "クリックまたはReturnで取り込み対象から外す" : "クリックまたはReturnで取り込み対象にする"
        }
        switch item.status {
        case .checking: return "照合が終わるまで選択できません"
        case .imported: return "保存先に同一内容があるため選択できません"
        case .cardDuplicate: return "カード内の同一内容は代表の1件だけを取り込みます"
        case .needsDate: return "撮影日時を指定すると選択できます"
        case .failed: return item.message.isEmpty ? "再読み込みして再計画すると選択できます" : item.message
        case .copying, .verifying: return "処理中のため操作できません"
        case .new: return ""
        }
    }
}
