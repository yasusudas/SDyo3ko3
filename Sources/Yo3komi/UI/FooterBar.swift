import SwiftUI

/// Bottom bar: selection summary and the import button when idle, live progress and stop while
/// scanning or importing. The import button reflects every selected item, including filtered-out ones.
struct FooterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isImporting {
                importingContent
            } else if model.isScanning {
                scanningContent
            } else {
                idleContent
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color.ykChrome)
        .overlay(alignment: .top) { Rectangle().fill(Color.ykSeparator).frame(height: 1) }
    }

    // MARK: Idle

    private var supplementOnlyCount: Int {
        model.selectedItems.filter { !$0.isSelected && $0.supplementSelected }.count
    }

    private var insufficientSpace: Bool {
        model.isDestinationConnected && model.selectedBytes > 0 && UIFormat.requiredWithMargin(model.selectedBytes) > model.availableBytes
    }

    @ViewBuilder private var idleContent: some View {
        HStack(spacing: 6) {
            Button("全選択") { model.selectVisible(true) }
                .buttonStyle(FlatButtonStyle())
                .help("現在の絞り込みで表示中の、選択可能な項目だけをオンにします（⌘A）")
            Button("解除") { model.selectVisible(false) }
                .buttonStyle(FlatButtonStyle())
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("現在の絞り込みで表示中の、選択可能な項目だけをオフにします（⇧⌘A）")
        }
        .disabled(model.isBusy || model.items.isEmpty)

        VStack(alignment: .leading, spacing: 2) {
            Text(selectionHeadline)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.ykPrimary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if insufficientSpace {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ykCritical)
                        .accessibilityHidden(true)
                }
                Text(selectionDetail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(insufficientSpace ? Color.ykPrimary : Color.ykSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .combine)
        .layoutPriority(1)

        Spacer(minLength: 8)

        thumbnailSlider

        Button {
            model.startImport()
        } label: {
            Text(importTitle)
                .frame(minWidth: 120)
        }
        .buttonStyle(FlatButtonStyle(prominent: true))
        .controlSize(.large)
        .disabled(!model.canImport || insufficientSpace)
        .keyboardShortcut(.return, modifiers: .command)
        .help(importHelp)
    }

    private var selectionHeadline: String {
        var text = "選択 \(UIFormat.count(model.selectedCount))・\(formattedBytes(model.selectedBytes))"
        if supplementOnlyCount > 0 { text += "・付随補完 \(supplementOnlyCount)" }
        return text
    }

    private var selectionDetail: String {
        if insufficientSpace { return "空き容量不足（空き \(formattedBytes(model.availableBytes))）" }
        if !model.isSourceConnected || !model.isDestinationConnected { return model.statusMessage }
        var parts = ["写真 \(model.selectedPhotoCount)", "動画 \(model.selectedVideoCount)"]
        if model.selectedSidecarCount > 0 { parts.append("付随 \(model.selectedSidecarCount)") }
        parts.append("取り込み済み \(model.importedCount)")
        if model.attentionCount > 0 { parts.append("保留 \(model.attentionCount)") }
        return parts.joined(separator: " · ")
    }

    private var importTitle: String {
        if model.selectedCount > 0 { return "\(model.selectedCount.formatted())件を取り込む" }
        if supplementOnlyCount > 0 { return "付随ファイルを補完" }
        return "取り込む"
    }

    private var importHelp: String {
        if insufficientSpace { return "保存先の空き容量が足りません" }
        if !model.isSourceConnected { return "取り込み元が接続されていません" }
        if !model.isDestinationConnected { return "保存先が接続されていません" }
        if model.selectedItems.isEmpty { return "取り込む項目が選択されていません" }
        if !model.canImport { return "照合が完了すると開始できます" }
        return "選択した項目を保存先へコピーし、内容を検証します（⌘Return）"
    }

    private var thumbnailSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("サムネイルサイズ: \(Int(model.thumbnailSize))×\(Int(model.thumbnailSize * 2 / 3))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.ykSecondary)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(Color.ykTertiary)
                Slider(value: $model.thumbnailSize, in: 120...360, onEditingChanged: { editing in
                    if !editing { model.settingsChanged() }
                })
                .controlSize(.small)
                .frame(width: 110)
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(Color.ykTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("サムネイルサイズ")
        .accessibilityValue("幅\(Int(model.thumbnailSize))、高さ\(Int(model.thumbnailSize * 2 / 3))ポイント")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.thumbnailSize = min(360, model.thumbnailSize + 20)
            case .decrement: model.thumbnailSize = max(120, model.thumbnailSize - 20)
            @unknown default: break
            }
            model.settingsChanged()
        }
        .help("サムネイルの大きさ")
    }

    // MARK: Scanning

    @ViewBuilder private var scanningContent: some View {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: 3) {
            Text(model.statusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.ykPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if model.scanTotal > 0 {
                    ProgressView(value: Double(min(model.scanCompleted, model.scanTotal)), total: Double(model.scanTotal))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                    Text("\(model.scanCompleted.formatted()) / \(model.scanTotal.formatted())")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.ykSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        Spacer(minLength: 8)
        Button("スキャンを停止") { model.stop() }
            .buttonStyle(FlatButtonStyle())
            .keyboardShortcut(".", modifiers: .command)
            .help("スキャンを停止します（⌘.）。再読み込みで再開できます")
    }

    // MARK: Importing

    @ViewBuilder private var importingContent: some View {
        let progress = model.progress
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(progress.phase.isEmpty ? "準備中" : progress.phase)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ykPrimary)
                Text("\(progress.completed.formatted()) / \(progress.total.formatted())件 確定")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.ykPrimary)
                if !progress.currentName.isEmpty {
                    Text(progress.currentName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ykSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
            HStack(spacing: 10) {
                Text("\(formattedBytes(progress.bytesCopied)) / \(formattedBytes(progress.totalBytes))")
                if let speed = UIFormat.speed(progress.bytesPerSecond) {
                    Text("\(progress.phase == "検証中" ? "検証" : "コピー") \(speed)")
                }
                if let remaining = UIFormat.remaining(progress) { Text(remaining) }
                Text("\(Int((progress.fraction * 100).rounded(.down)))%")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Color.ykSecondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("取り込み中、\(progress.phase)、\(progress.completed)件確定、全\(progress.total)件")
        Spacer(minLength: 8)
        Button("停止") { model.stop() }
            .buttonStyle(FlatButtonStyle())
            .keyboardShortcut(".", modifiers: .command)
            .help("現在のファイルを安全な区切りで止め、新しいコピーを開始しません（⌘.）。確定済みのファイルは保持されます")
    }
}
