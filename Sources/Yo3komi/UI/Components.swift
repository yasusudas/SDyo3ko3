import SwiftUI
import AppKit

// MARK: - Buttons

/// Compact text button. Secondary actions have no outline, only a faint neutral surface that
/// strengthens on hover and press; `prominent` is kept for the single primary action in view.
/// `.controlSize(.large)` gives the taller footer variant.
struct FlatButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct FlatButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var large: Bool { controlSize == .large || controlSize == .extraLarge }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Color.ykPrimary)
                .padding(.horizontal, large ? 14 : 8)
                .frame(minHeight: large ? 28 : 22)
                .background(background, in: shape)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.4)
        }

        private var background: Color {
            let hot = hovering && isEnabled
            if prominent {
                let base = Color.accentColor
                return configuration.isPressed ? base.opacity(0.78) : (hot ? base.opacity(0.9) : base)
            }
            if configuration.isPressed { return Color.ykPrimary.opacity(0.16) }
            return Color.ykPrimary.opacity(hot ? 0.1 : 0.055)
        }
    }
}

/// Borderless symbol button for toolbars and compact rows.
struct SymbolButton: View {
    var symbol: String
    var help: String
    var pointSize: CGFloat = 13
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: pointSize, weight: .regular))
                .frame(width: pointSize + 11, height: max(18, pointSize + 9))
                .background(hovering && isEnabled ? Color.ykPrimary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ykSecondary)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Panel building blocks

struct PanelHeader<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ykSecondary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct MetricRow: View {
    var label: String
    var value: String
    var valueColor: Color = .ykPrimary
    var symbol: String? = nil
    var symbolColor: Color = .ykTertiary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(symbolColor).frame(width: 14)
            }
            Text(label).foregroundStyle(Color.ykSecondary)
            Spacer(minLength: 6)
            Text(value).foregroundStyle(valueColor).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

/// Inline state or note: a small symbol followed by plain text, with no plate behind it.
/// Color, when used at all, goes on the symbol; the text keeps the meaning.
struct StatusLabel: View {
    var symbol: String
    var text: String
    var tint: Color = .ykNeutral
    var textColor: Color = .ykSecondary
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: fontSize - 1, weight: .medium))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

extension StatusLabel {
    init(item: MediaItem) {
        let style = StatusStyle(item)
        self.init(symbol: style.symbol, text: style.label, tint: Color(nsColor: style.tint), textColor: Color(nsColor: style.textColor))
    }
}

/// Connection state as a small dot and plain text, with no plate behind it. The dot and the text
/// share the state color (connected green, disconnected red, access error amber); unset stays neutral.
/// Each state also has its own wording, so the color is never the only cue.
struct ConnectionLabel: View {
    var state: ConnectionState

    private var text: String {
        switch state {
        case .connected: return "接続中"
        case .disconnected: return "未接続"
        case .error: return "アクセスエラー"
        case .unconfigured: return "未設定"
        }
    }

    private var tint: Color {
        switch state {
        case .connected: return .ykPositiveText
        case .disconnected: return .ykCriticalText
        case .error: return .ykCautionText
        case .unconfigured: return .ykNeutral
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

enum NoticeKind { case info, success, warning, error }

/// Inline notice for errors, warnings, recovery and completion. Text always carries the meaning;
/// only warnings and errors tint their symbol.
struct NoticeBanner<Actions: View>: View {
    typealias Kind = NoticeKind
    var kind: Kind
    var title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    init(_ kind: Kind, title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info, .success: return .ykNeutral
        case .warning: return .ykCaution
        case .error: return .ykCritical
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 13)).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ykPrimary)
                if let message, !message.isEmpty {
                    Text(message).font(.system(size: 11)).foregroundStyle(Color.ykSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.ykPanel)
        .accessibilityElement(children: .contain)
    }
}

extension PanelHeader where Accessory == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

extension NoticeBanner where Actions == EmptyView {
    init(_ kind: Kind, title: String, message: String? = nil) {
        self.init(kind, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Column resizing

/// One-point separator with a wider invisible grab area, used between the three columns.
struct ColumnResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    /// +1 when dragging right widens the column (left column), -1 for the right column.
    var direction: Double
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.ykSeparator)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                width = min(range.upperBound, max(range.lowerBound, base + direction * value.translation.width))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .accessibilityHidden(true)
    }
}

// MARK: - Helpers

extension View {
    func panelBackground() -> some View { background(Color.ykPanel) }
}
