import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Small label drawn over the photo (format, duration, sidecars). The fixed dark translucent
/// plate exists only for legibility on arbitrary images in both appearances; it is never tinted.
final class OverlayBadge: NSView {
    private static let plate = NSColor(white: 0, alpha: 0.55)
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hasIcon = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.badgeRadius
        layer?.backgroundColor = Self.plate.cgColor
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func set(text: String, symbol: String? = nil) {
        label.stringValue = text
        hasIcon = symbol != nil
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = !hasIcon
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        ceil(label.intrinsicContentSize.width) + (hasIcon ? 12 : 0) + 10
    }

    override func layout() {
        super.layout()
        let iconWidth: CGFloat = hasIcon ? 10 : 0
        icon.frame = NSRect(x: 5, y: (bounds.height - 10) / 2, width: iconWidth, height: 10)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 5 + (hasIcon ? 12 : 0), y: (bounds.height - labelHeight) / 2, width: bounds.width - 10 - (hasIcon ? 12 : 0), height: labelHeight)
    }
}

/// One grid tile. Frame-based layout (no Auto Layout) keeps reuse cheap while scrolling 10k items.
final class MediaTileView: NSView {
    static let captionHeight: CGFloat = 40

    let imageView = NSImageView()
    private let fallbackIcon = NSImageView()
    private let fallbackLabel = NSTextField(labelWithString: "")
    private let checkboxPlate = NSView()
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let formatBadge = OverlayBadge()
    private let durationBadge = OverlayBadge()
    private let sidecarBadge = OverlayBadge()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var grayscale: CIFilter? = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.0])

    var isFocused = false { didSet { if oldValue != isFocused { needsDisplay = true } } }
    private var isHovering = false { didSet { if oldValue != isHovering { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private var showsActivity = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = Theme.tileRadius
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layerUsesCoreImageFilters = true
        imageView.setAccessibilityElement(false)
        addSubview(imageView)

        fallbackIcon.imageScaling = .scaleProportionallyUpOrDown
        fallbackIcon.setAccessibilityElement(false)
        addSubview(fallbackIcon)
        fallbackLabel.font = .systemFont(ofSize: 10)
        fallbackLabel.textColor = Theme.secondaryText
        fallbackLabel.alignment = .center
        fallbackLabel.maximumNumberOfLines = 2
        fallbackLabel.lineBreakMode = .byWordWrapping
        addSubview(fallbackLabel)

        // Just enough backing to keep the checkbox legible over a photo; hugs the control.
        checkboxPlate.wantsLayer = true
        checkboxPlate.layer?.cornerRadius = Theme.badgeRadius
        checkboxPlate.layer?.backgroundColor = NSColor(white: 0, alpha: 0.32).cgColor
        addSubview(checkboxPlate)
        checkbox.controlSize = .regular
        checkbox.focusRingType = .exterior
        addSubview(checkbox)

        for badge in [formatBadge, durationBadge, sidecarBadge] { addSubview(badge) }

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = Theme.primaryText
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setAccessibilityElement(false)
        addSubview(nameLabel)

        statusIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        statusIcon.setAccessibilityElement(false)
        addSubview(statusIcon)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityElement(false)
        addSubview(statusLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// Frame-based subviews (and the owning item's thumbnail size) follow every tile resize.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func updateLayer() {
        // The tile surface alone separates tiles; a resting outline returns only for Increase Contrast.
        let outlined = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isHovering ? Theme.tileHover : Theme.tile).cgColor
            layer?.borderWidth = isFocused ? 2 : (outlined ? 1 : 0)
            layer?.borderColor = (isFocused ? Theme.accent : Theme.separator).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    // MARK: Content

    struct Content {
        var name: String
        var formatText: String
        var isRaw: Bool
        var duration: String?
        var sidecarCount: Int
        var isChecked: Bool
        var canSelect: Bool
        var style: StatusStyle
        var statusText: String
        var accessibilitySummary: String
        var checkboxHelp: String
    }

    func apply(_ content: Content) {
        nameLabel.stringValue = content.name
        nameLabel.toolTip = content.name

        formatBadge.set(text: content.isRaw ? "RAW · \(content.formatText)" : content.formatText)
        durationBadge.isHidden = content.duration == nil
        if let duration = content.duration { durationBadge.set(text: duration, symbol: "play.fill") }
        sidecarBadge.isHidden = content.sidecarCount == 0
        if content.sidecarCount > 0 { sidecarBadge.set(text: "\(content.sidecarCount)", symbol: "paperclip") }

        checkbox.state = content.isChecked ? .on : .off
        checkbox.isEnabled = content.canSelect
        checkbox.toolTip = content.checkboxHelp
        checkbox.setAccessibilityLabel("取り込み対象: \(content.name)")
        checkbox.setAccessibilityHelp(content.checkboxHelp)
        checkboxPlate.alphaValue = content.canSelect ? 1 : 0.5

        statusIcon.image = NSImage(systemSymbolName: content.style.symbol, accessibilityDescription: nil)
        statusIcon.contentTintColor = content.style.tint
        statusLabel.stringValue = content.statusText
        statusLabel.textColor = content.style.textColor
        statusLabel.toolTip = content.statusText
        showsActivity = content.style.showsActivity
        if showsActivity { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        let dims = content.style.dimsThumbnail
        imageView.alphaValue = dims ? 0.38 : 1
        imageView.contentFilters = dims ? (grayscale.map { [$0] } ?? []) : []
        fallbackIcon.alphaValue = dims ? 0.38 : 1

        setAccessibilityLabel(content.accessibilitySummary)
        needsLayout = true
    }

    enum ThumbnailState { case loading, image(NSImage), unavailable(fileExtension: String) }

    func setThumbnail(_ state: ThumbnailState) {
        switch state {
        case .loading:
            imageView.image = nil
            fallbackIcon.image = nil
            fallbackLabel.stringValue = ""
        case .image(let image):
            imageView.image = image
            fallbackIcon.image = nil
            fallbackLabel.stringValue = ""
        case .unavailable(let ext):
            imageView.image = nil
            let type = UTType(filenameExtension: ext.lowercased()) ?? .data
            fallbackIcon.image = NSWorkspace.shared.icon(for: type)
            fallbackLabel.stringValue = "プレビューなし\n原本はコピーできます"
        }
        needsLayout = true
    }

    var hasThumbnailImage: Bool { imageView.image != nil }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let wellHeight = max(0, bounds.height - Self.captionHeight)
        let well = NSRect(x: 0, y: 0, width: w, height: wellHeight)
        imageView.frame = well.insetBy(dx: 6, dy: 6)

        let iconSide = min(56, wellHeight * 0.4)
        fallbackIcon.frame = NSRect(x: (w - iconSide) / 2, y: wellHeight / 2 - iconSide + 4, width: iconSide, height: iconSide)
        fallbackLabel.frame = NSRect(x: 8, y: fallbackIcon.frame.maxY + 4, width: w - 16, height: 28)

        checkboxPlate.frame = NSRect(x: 7, y: 7, width: 20, height: 20)
        let box = checkbox.fittingSize
        checkbox.frame = NSRect(x: checkboxPlate.frame.midX - box.width / 2 + 1, y: checkboxPlate.frame.midY - box.height / 2, width: box.width, height: box.height)

        let badgeHeight: CGFloat = 16
        let formatWidth = min(w - 44, formatBadge.fittingWidth)
        formatBadge.frame = NSRect(x: w - formatWidth - 7, y: 9, width: formatWidth, height: badgeHeight)
        let durationWidth = durationBadge.fittingWidth
        durationBadge.frame = NSRect(x: w - durationWidth - 7, y: wellHeight - badgeHeight - 7, width: durationWidth, height: badgeHeight)
        sidecarBadge.frame = NSRect(x: 7, y: wellHeight - badgeHeight - 7, width: sidecarBadge.fittingWidth, height: badgeHeight)

        nameLabel.frame = NSRect(x: 8, y: wellHeight + 3, width: w - 16, height: 16)
        statusIcon.frame = NSRect(x: 8, y: wellHeight + 22, width: 12, height: 13)
        let spinnerSide: CGFloat = showsActivity ? 16 : 0
        statusLabel.frame = NSRect(x: 24, y: wellHeight + 20, width: max(0, w - 32 - spinnerSide), height: 15)
        spinner.frame = NSRect(x: w - 8 - 14, y: wellHeight + 21, width: 14, height: 14)
    }
}
