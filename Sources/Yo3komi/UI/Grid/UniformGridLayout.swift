import AppKit

/// Uniform tile grid whose cost is proportional to the visible rect, not the item count.
/// Columns adapt to the available width; tiles stretch slightly so rows always fill edge to edge.
final class UniformGridLayout: NSCollectionViewLayout {
    var preferredTileWidth: CGFloat = 180 { didSet { if oldValue != preferredTileWidth { invalidateLayout() } } }
    let spacing: CGFloat = 10
    let insets = NSEdgeInsets(top: 12, left: 14, bottom: 16, right: 14)
    /// Height of the caption block below the image well (file name + status line).
    let captionHeight: CGFloat = 40

    private(set) var columns = 1
    private(set) var tileSize = NSSize(width: 180, height: 175)
    private var itemCount = 0
    private var lastWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        itemCount = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let width = availableWidth(collectionView)
        lastWidth = width
        let usable = max(1, width - insets.left - insets.right)
        columns = max(1, Int((usable + spacing) / (preferredTileWidth + spacing)))
        let tileWidth = floor((usable - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        // 3:2 image well matches most stills; portrait and video frames are aspect-fit inside it.
        tileSize = NSSize(width: tileWidth, height: floor(tileWidth * 2 / 3) + captionHeight)
    }

    private func availableWidth(_ collectionView: NSCollectionView) -> CGFloat {
        collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
    }

    private var rows: Int { itemCount == 0 ? 0 : (itemCount + columns - 1) / columns }

    override var collectionViewContentSize: NSSize {
        let height = rows == 0 ? 0 : insets.top + insets.bottom + CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * spacing
        return NSSize(width: lastWidth, height: height)
    }

    func frame(for index: Int) -> NSRect {
        let row = index / columns, column = index % columns
        return NSRect(x: insets.left + CGFloat(column) * (tileSize.width + spacing),
                      y: insets.top + CGFloat(row) * (tileSize.height + spacing),
                      width: tileSize.width, height: tileSize.height)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard itemCount > 0 else { return [] }
        let rowHeight = tileSize.height + spacing
        let firstRow = max(0, Int((rect.minY - insets.top) / rowHeight))
        let lastRow = min(rows - 1, Int((rect.maxY - insets.top) / rowHeight))
        guard firstRow <= lastRow else { return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        result.reserveCapacity((lastRow - firstRow + 1) * columns)
        for row in firstRow...lastRow {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < itemCount else { break }
                result.append(attributes(at: index))
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < itemCount else { return nil }
        return attributes(at: indexPath.item)
    }

    private func attributes(at index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame(for: index)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - lastWidth) > 0.5
    }

    /// Index reached by moving `rowDelta` rows and `columnDelta` columns, clamped to the grid.
    func index(from index: Int, rowDelta: Int, columnDelta: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        if columnDelta != 0 { return min(itemCount - 1, max(0, index + columnDelta)) }
        let target = index + rowDelta * columns
        if target < 0 { return index % columns }
        return min(itemCount - 1, target)
    }

    var itemsPerPage: Int {
        guard let collectionView else { return columns }
        let visibleRows = max(1, Int(collectionView.visibleRect.height / (tileSize.height + spacing)))
        return visibleRows * columns
    }
}
