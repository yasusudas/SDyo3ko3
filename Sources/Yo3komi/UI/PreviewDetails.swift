import SwiftUI
import AppKit

/// Full metadata and per-item actions shown beside the large preview.
struct PreviewDetails: View {
    @ObservedObject var model: AppModel
    let item: MediaItem
    @State private var showDateEditor = false

    private var canChangeDate: Bool { item.status != .imported && item.status != .cardDuplicate }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            section("取り込み") { selectionControls }
            section("撮影日時と保存先") { dateSection }
            section("ファイル") { fileSection }
            if !item.related.isEmpty || !item.supplementURLs.isEmpty {
                section("付随ファイル") { sidecarSection }
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ykPrimary)
                .textSelection(.enabled)
            HStack(alignment: .center, spacing: 8) {
                StatusLabel(item: item)
                Rectangle().fill(Color.ykSeparator).frame(width: 1, height: 10).accessibilityHidden(true)
                Text(UIFormat.kindLabel(item) + (item.fileExtension.isEmpty ? "" : " · \(item.fileExtension)"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ykSecondary)
            }
            if !item.message.isEmpty {
                Text(item.message)
                    .font(.system(size: 11))
                    .foregroundStyle(item.status == .failed ? Color.ykPrimary : Color.ykSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { item.canSelect && item.isSelected }, set: { _ in model.toggleSelection(item.id) })) {
                Text("この項目を取り込む").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(!item.canSelect || model.isBusy)
            .accessibilityHint(MediaTileItem.selectionHelp(item, interactive: !model.isBusy))
            if !item.canSelect {
                Text(MediaTileItem.selectionHelp(item, interactive: !model.isBusy))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ykTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("撮影日時", UIFormat.captureDate(item.captureDate, zoneID: model.timeZoneID))
            detailRow("根拠", item.dateEvidence.isEmpty ? "—" : item.dateEvidence)
            detailRow("撮影地TZ", model.timeZoneID)
            detailRow("日付フォルダ", item.dateFolder ?? "未定（保留）")
            if let destination = item.destinationURL, item.status != .imported {
                detailRow("保存予定", destination.path, monospaced: true)
            }
            if let duplicate = item.duplicateURL {
                detailRow(item.status == .imported ? "保存済みの場所" : "同一内容", duplicate.path, monospaced: true)
            }
            if canChangeDate {
                if item.status == .needsDate || showDateEditor {
                    DateResolutionForm(model: model, item: item, compact: true) { showDateEditor = false }
                        .padding(10)
                        .background(Color.ykRaised, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                        .padding(.top, 4)
                } else {
                    Button("撮影日時を修正…") { showDateEditor = true }
                        .buttonStyle(FlatButtonStyle())
                        .disabled(model.isBusy)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("容量", "\(formattedBytes(item.byteCount))（\(item.byteCount.formatted()) バイト）")
            if let duration = UIFormat.duration(item.duration) { detailRow("再生時間", duration) }
            detailRow("元の場所", item.relativePath, monospaced: true)
            detailRow("更新日時", UIFormat.fileDate(item.stamp.modified))
            if let digest = item.digest {
                detailRow("SHA-256", digest, monospaced: true)
            }
        }
    }

    private var sidecarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(item.related) { related in
                let missing = item.supplementURLs.contains(related.url)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: missing ? "paperclip.badge.ellipsis" : "paperclip")
                        .foregroundStyle(missing ? Color.ykCaution : Color.ykTertiary)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(related.url.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ykPrimary)
                        Text(sidecarDetail(related, missing: missing))
                            .font(.system(size: 10))
                            .foregroundStyle(Color.ykTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !item.supplementURLs.isEmpty {
                Toggle(isOn: Binding(get: { item.supplementSelected }, set: { _ in model.toggleSupplement(item.id) })) {
                    Text("不足している付随ファイル\(item.supplementURLs.count)件を補完する")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .disabled(model.isBusy)
                Text("メディア本体はコピーしません。保存先の既存の付随ファイルは上書きしません。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ykTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if item.isSelected {
                Text("メディアと同じ日付フォルダへ一緒にコピーします。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ykTertiary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("元ファイルを表示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                .buttonStyle(FlatButtonStyle())
            if item.duplicateURL != nil || item.destinationURL != nil {
                Button(item.status == .imported ? "保存先を表示" : "保存予定先を表示") { model.revealItem(item) }
                    .buttonStyle(FlatButtonStyle())
            }
        }
    }

    // MARK: Helpers

    private func sidecarDetail(_ related: RelatedFile, missing: Bool) -> String {
        var parts: [String] = []
        if related.targetName != related.url.lastPathComponent { parts.append("保存名 \(related.targetName)") }
        parts.append(formattedBytes(related.stamp.size))
        if missing { parts.append("保存先に不足") }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.ykSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.ykSeparator).frame(height: 1) }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.ykTertiary)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .foregroundStyle(Color.ykPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
