import SwiftUI
import AppKit

/// Root of the main window: source column, photo grid, destination column and footer.
/// Column widths are user-resizable and persisted; on narrow windows the side columns
/// collapse automatically so the grid keeps priority.
struct MainWindowView: View {
    @ObservedObject var model: AppModel

    @AppStorage("ui.leftWidth") private var leftWidth = 200.0
    @AppStorage("ui.rightWidth") private var rightWidth = 240.0
    @AppStorage("ui.showLeft") private var showLeft = true
    @AppStorage("ui.showRight") private var showRight = true
    @State private var dateTarget: MediaItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let leftRange = 160.0...240.0
    private static let rightRange = 200.0...300.0
    private static let minimumCenter = 520.0

    var body: some View {
        GeometryReader { proxy in
            let layout = columnLayout(totalWidth: proxy.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if layout.left {
                        SourcePanel(model: model)
                            .frame(width: clamped(leftWidth, Self.leftRange))
                        ColumnResizeHandle(width: $leftWidth, range: Self.leftRange, direction: 1)
                            .zIndex(1)
                    }
                    centerColumn
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .layoutPriority(1)
                    if layout.right {
                        ColumnResizeHandle(width: $rightWidth, range: Self.rightRange, direction: -1)
                            .zIndex(1)
                        DestinationPanel(model: model, onRequestDateResolution: { dateTarget = $0 })
                            .frame(width: clamped(rightWidth, Self.rightRange))
                    }
                }
                FooterBar(model: model)
            }
        }
        .background(Color.ykWindow)
        .foregroundStyle(Color.ykPrimary)
        .navigationTitle("yo3komi")
        .toolbar { toolbarContent }
        .toolbarBackground(Color.ykChrome, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(item: $model.previewItem) { item in
            PreviewSheet(model: model, initialID: item.id)
        }
        .sheet(item: $dateTarget) { item in
            DateResolutionSheet(model: model, item: item)
        }
    }

    // MARK: Columns

    private func clamped(_ value: Double, _ range: ClosedRange<Double>) -> CGFloat {
        CGFloat(min(range.upperBound, max(range.lowerBound, value)))
    }

    private func columnLayout(totalWidth: CGFloat) -> (left: Bool, right: Bool) {
        let width = Double(totalWidth)
        let left = clamped(leftWidth, Self.leftRange), right = clamped(rightWidth, Self.rightRange)
        var showsLeft = showLeft, showsRight = showRight
        if showsLeft && width - Double(left) - (showsRight ? Double(right) : 0) < Self.minimumCenter { showsLeft = false }
        if showsRight && width - (showsLeft ? Double(left) : 0) - Double(right) < Self.minimumCenter { showsRight = false }
        return (showsLeft, showsRight)
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            FilterBar(model: model)
            Rectangle().fill(Color.ykSeparator).frame(height: 1)
            // Result of history export/import, which can be started from the ⋯ menu as well as Settings.
            if let message = model.historyMessage, !model.isManagingHistory {
                NoticeBanner(.info, title: "取り込み履歴", message: message) {
                    Button("閉じる") { model.historyMessage = nil }.buttonStyle(FlatButtonStyle())
                }
                Rectangle().fill(Color.ykSeparator).frame(height: 1)
            }
            CenterNotices(model: model, onRequestDateResolution: { dateTarget = $0 })
            ZStack {
                MediaGridView(model: model, onRequestDateResolution: { dateTarget = $0 })
                GridEmptyState(model: model)
            }
        }
        .background(Color.ykGrid)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showLeft.toggle() }
            } label: {
                Label("取り込み元を表示", systemImage: "sidebar.left")
            }
            .help(showLeft ? "取り込み元の列を隠す" : "取り込み元の列を表示")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.refresh()
            } label: {
                Label("再読み込み", systemImage: "arrow.clockwise")
            }
            .disabled(model.isImporting)
            .help("取り込み元と保存先を再照合（⌘R）")

            Menu {
                Button("内容を再検証（フルハッシュ）") { model.refresh(force: true) }
                    .disabled(model.isBusy)
                Button("ボリューム一覧を更新") { model.refreshVolumes() }
                Divider()
                Button("保存先をFinderで開く") { model.revealDestination() }
                    .disabled(!model.isDestinationConnected)
                Divider()
                Button("取り込み履歴を書き出す…") { model.exportHistory() }
                    .disabled(model.isBusy)
                Button("取り込み履歴を読み込む…") { model.importHistory() }
                    .disabled(model.isBusy)
            } label: {
                Label("その他", systemImage: "ellipsis.circle")
            }
            .help("その他の操作")

            SettingsLink {
                Label("設定", systemImage: "gearshape")
            }
            .help("設定（⌘,）")

            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showRight.toggle() }
            } label: {
                Label("保存先を表示", systemImage: "sidebar.right")
            }
            .help(showRight ? "保存先の列を隠す" : "保存先の列を表示")
        }
    }
}
