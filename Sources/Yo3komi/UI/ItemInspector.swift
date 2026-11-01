import SwiftUI
import AppKit

/// Compact detail for the focused tile, pinned to the bottom of the right column.
/// Gives keyboard users the date, destination and sidecar actions without opening the preview.
struct ItemInspector: View {
    @ObservedObject var model: AppModel
    var onRequestDateResolution: (MediaItem) -> Void
    @AppStorage("ui.inspector.expanded") private var expanded = true

    private var item: MediaItem? {
        guard let id = model.focusedItemID else { return nil }
        return model.items.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("ファイル詳細")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ykSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .foregroundStyle(Color.ykTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ファイル詳細")
            .accessibilityValue(expanded ? "展開" : "折りたたみ")

            if expanded {
                Group {
                    if let item { content(item) }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(Color.ykChrome)
    }

    private func content(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ykPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.relativePath)
                Spacer(minLength: 0)
            }
            StatusLabel(item: item)
            MetricRow(label: "撮影", value: UIFormat.captureDate(item.captureDate, zoneID: model.timeZoneID))
                .help(item.dateEvidence.isEmpty ? "根拠なし" : "根拠: \(item.dateEvidence)")
            MetricRow(label: "保存先", value: item.dateFolder ?? "未定")
            MetricRow(label: "容量", value: formattedBytes(item.byteCount))
            if !item.message.isEmpty {
                Text(item.message)
                    .font(.system(size: 10))
                    .foregroundStyle(item.status == .failed ? Color.ykPrimary : Color.ykSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(item.message)
            }
            if !item.supplementURLs.isEmpty {
                Toggle(isOn: Binding(get: { item.supplementSelected }, set: { _ in model.toggleSupplement(item.id) })) {
                    Text("付随ファイル\(item.supplementURLs.count)件を補完")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .disabled(model.isBusy)
                .help("保存済みメディアに不足している付随ファイルだけをコピーします。既存の付随ファイルは上書きしません。")
            }
            HStack(spacing: 6) {
                Button("詳細…") { model.showPreview(item) }
                    .buttonStyle(FlatButtonStyle())
                    .help("プレビューと全メタデータ（Space）")
                if item.status == .needsDate || (item.status == .new && item.captureDate == nil) {
                    Button("日時を指定…") { onRequestDateResolution(item) }
                        .buttonStyle(FlatButtonStyle())
                        .disabled(model.isBusy)
                }
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
    }
}
