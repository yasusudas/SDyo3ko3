import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

/// Large preview plus every piece of metadata the model knows about one item.
/// Navigation walks the current filtered list without dismissing the sheet.
struct PreviewSheet: View {
    @ObservedObject var model: AppModel
    @State private var currentID: String
    @FocusState private var mediaFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, initialID: String) {
        self.model = model
        _currentID = State(initialValue: initialID)
    }

    private var item: MediaItem? { model.items.first { $0.id == currentID } }

    private var neighbours: (previous: MediaItem?, next: MediaItem?) {
        let list = model.visibleItems
        guard let index = list.firstIndex(where: { $0.id == currentID }) else { return (nil, nil) }
        return (index > 0 ? list[index - 1] : nil, index + 1 < list.count ? list[index + 1] : nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            mediaPane
            Rectangle().fill(Color.ykSeparator).frame(width: 1)
            ScrollView {
                if let item {
                    PreviewDetails(model: model, item: item)
                        .id(item.id)
                        .padding(16)
                } else {
                    Text("この項目は一覧から外れました。")
                        .foregroundStyle(Color.ykSecondary)
                        .padding(16)
                }
            }
            .frame(width: 320)
            .background(Color.ykPanel)
        }
        .frame(minWidth: 960, idealWidth: 1180, minHeight: 620, idealHeight: 780)
        .background(Color.ykWindow)
        .onAppear { mediaFocused = true }
    }

    // MARK: Media

    private var mediaPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SymbolButton(symbol: "chevron.left", help: "前の項目（←）") { go(neighbours.previous) }
                    .disabled(neighbours.previous == nil)
                SymbolButton(symbol: "chevron.right", help: "次の項目（→）") { go(neighbours.next) }
                    .disabled(neighbours.next == nil)
                Text(item?.name ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ykPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("閉じる") { dismiss() }
                    .buttonStyle(FlatButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("閉じる（Esc / Space）")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.ykChrome)
            Rectangle().fill(Color.ykSeparator).frame(height: 1)
            ZStack {
                Color.ykGrid
                if let item {
                    if item.isVideo {
                        VideoPreview(url: item.url).id(item.id)
                    } else {
                        PhotoPreview(item: item).id(item.id)
                    }
                }
            }
            .focusable()
            .focused($mediaFocused)
            .onKeyPress(.leftArrow) { go(neighbours.previous); return .handled }
            .onKeyPress(.rightArrow) { go(neighbours.next); return .handled }
            .onKeyPress(.space) { dismiss(); return .handled }
            .onKeyPress(.return) {
                if let item, item.canSelect, !model.isBusy { model.toggleSelection(item.id) }
                return .handled
            }
            .accessibilityLabel(item.map { "\($0.name)のプレビュー" } ?? "プレビュー")
            .accessibilityHint("左右の矢印キーで前後の項目、Returnで取り込み対象を切り替え、SpaceまたはEscで閉じます")
        }
    }

    private func go(_ target: MediaItem?) {
        guard let target else { return }
        currentID = target.id
        model.focusedItemID = target.id
    }
}

// MARK: - Media views

private struct PhotoPreview: View {
    let item: MediaItem
    @State private var image: NSImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
                    .accessibilityHidden(true)
            } else if finished {
                VStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: item.url.pathExtension.lowercased()) ?? .data))
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("この形式のプレビューを生成できませんでした")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ykPrimary)
                    Text("原本のコピーには影響しません。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ykSecondary)
                }
            } else {
                ProgressView().controlSize(.regular)
            }
        }
        .task(id: item.id) {
            // Parent service returns the embedded RAW preview where available; never decodes for edits.
            let loaded = await ThumbnailService.shared.thumbnail(for: item.url, maxPixelSize: 1800)
            guard !Task.isCancelled else { return }
            image = loaded
            finished = true
        }
    }
}

private struct VideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        view.setAccessibilityLabel("動画プレビュー")
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
