import SwiftUI

/// Picks a capture date in the configured shooting time zone and hands it to the model.
/// Nothing is written to the original files; the model only re-plans the destination folder.
struct DateResolutionForm: View {
    @ObservedObject var model: AppModel
    let item: MediaItem
    var compact = false
    var onDone: () -> Void = {}

    enum Scope: Hashable { case single, allUndated }
    @State private var date: Date
    @State private var scope: Scope = .single

    init(model: AppModel, item: MediaItem, compact: Bool = false, onDone: @escaping () -> Void = {}) {
        self.model = model
        self.item = item
        self.compact = compact
        self.onDone = onDone
        _date = State(initialValue: item.captureDate ?? Date(timeIntervalSince1970: item.stamp.modified))
    }

    private var zone: TimeZone { TimeZone(identifier: model.timeZoneID) ?? .current }

    /// Other items that still need a date; only offered as an explicit bulk choice.
    private var undatedIDs: [String] {
        model.items.filter { $0.status == .needsDate }.map(\.id)
    }

    private var targetIDs: [String] {
        scope == .allUndated ? undatedIDs : [item.id]
    }

    private var canEdit: Bool {
        !model.isBusy && item.status != .imported && item.status != .cardDuplicate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            DatePicker("撮影日時", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .environment(\.timeZone, zone)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .labelsHidden(compact)
                .accessibilityLabel("撮影日時（\(zone.identifier)）")

            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(Color.ykTertiary)
                Text("保存先 \(MetadataReader.folder(for: date, zone: zone))")
                    .monospacedDigit()
                Text("・\(zone.identifier)")
                    .foregroundStyle(Color.ykTertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.ykSecondary)
            .accessibilityElement(children: .combine)

            if undatedIDs.count > 1 && item.status == .needsDate {
                Picker("適用範囲", selection: $scope) {
                    Text("このファイルのみ").tag(Scope.single)
                    Text("日時不明の\(undatedIDs.count)件すべて").tag(Scope.allUndated)
                }
                .pickerStyle(.radioGroup)
                .font(.system(size: 11))
            }

            HStack(spacing: 6) {
                Button("ファイル更新日時を使う") {
                    for id in targetIDs { model.useModificationDate(id) }
                    onDone()
                }
                .buttonStyle(FlatButtonStyle())
                .help("撮影日時ではなく、ファイルの更新日時（\(UIFormat.fileDate(item.stamp.modified))）で仕分けます")
                Spacer(minLength: 0)
                Button("この日時で確定") {
                    for id in targetIDs { model.resolveDate(id, date: date) }
                    onDone()
                }
                .buttonStyle(FlatButtonStyle(prominent: true))
                .keyboardShortcut(compact ? nil : .defaultAction)
            }
            .disabled(!canEdit)
            if !canEdit {
                Text(model.isBusy ? "処理中は日時を変更できません。" : "取り込み済みの項目の日時は変更できません。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ykTertiary)
            }
        }
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// Standalone sheet used from the grid's context menu, the inspector and the attention banner.
struct DateResolutionSheet: View {
    @ObservedObject var model: AppModel
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("撮影日時を指定")
                    .font(.system(size: 15, weight: .semibold))
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ykSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            NoticeBanner(.info,
                         title: item.status == .needsDate ? "撮影日時を安全に決められませんでした" : "仕分けに使う日付を変更します",
                         message: [item.message, item.dateEvidence.isEmpty ? nil : "根拠: \(item.dateEvidence)"]
                            .compactMap { $0?.isEmpty == false ? $0 : nil }
                            .joined(separator: "\n"))
            Text("指定した日時は保存先フォルダの決定だけに使い、元の写真・動画やEXIFは変更しません。時刻は撮影地のタイムゾーン（\(model.timeZoneID)）で入力します。")
                .font(.system(size: 11))
                .foregroundStyle(Color.ykSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DateResolutionForm(model: model, item: item) { dismiss() }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .buttonStyle(FlatButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.ykPanel)
    }
}
