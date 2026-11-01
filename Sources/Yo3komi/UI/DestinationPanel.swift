import SwiftUI
import AppKit

/// Year → MM-DD tree including existing folders; counts describe planned additions only.
struct DateTreeYear: Identifiable {
    var id: String { year }
    var year: String
    var days: [FolderSummary]
    var count: Int { days.reduce(0) { $0 + $1.count } }
    var hasSelectableItems = false

    static func build(_ summaries: [FolderSummary], selectableDates: Set<String> = []) -> [DateTreeYear] {
        let grouped = Dictionary(grouping: summaries) { UIFormat.splitFolder($0.path).year }
        let years = grouped.keys.sorted { a, b in
            // Chronological; anything unparseable (e.g. 日時不明) goes last.
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a < b
            }
        }
        return years.map { year in
            let days = grouped[year, default: []].sorted { lhs, rhs in lhs.path < rhs.path }
            return DateTreeYear(year: year, days: days, hasSelectableItems: days.contains { selectableDates.contains($0.path) })
        }
    }
}

struct DestinationPanel: View {
    @ObservedObject var model: AppModel
    var onRequestDateResolution: (MediaItem) -> Void
    @State private var yearExpansionOverrides: [String: Bool] = [:]

    private var destinationName: String {
        UIFormat.volumeName(of: model.destinationURL) ?? model.destinationURL?.lastPathComponent ?? "未設定"
    }

    var body: some View {
        let summaries = model.folderSummaries
        let selections = model.dateSelections
        let years = DateTreeYear.build(summaries, selectableDates: Set(selections.keys))
        let availableYears = years.filter { $0.hasSelectableItems || $0.count > 0 }.map(\.year)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PanelHeader("保存先")
                    destinationCard
                    PanelHeader("容量")
                    capacitySection
                    PanelHeader("日付フォルダ")
                    dateTree(years, selections: selections)
                    PanelHeader("今回の予定")
                    planSummary(summaries)
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            Divider().overlay(Color.ykSeparator)
            ItemInspector(model: model, onRequestDateResolution: onRequestDateResolution)
        }
        .panelBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("保存先")
        .onChange(of: availableYears) { _, _ in
            // Selection changes must not collapse the year containing the checkbox.
            yearExpansionOverrides.removeAll()
        }
        .onChange(of: model.destinationURL) { _, _ in
            yearExpansionOverrides.removeAll()
        }
    }

    // MARK: Destination

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.ykSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ykPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.destinationURL?.lastPathComponent ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ykSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(model.destinationURL?.path ?? "未設定")
            ConnectionLabel(state: model.destinationConnectionState)
            Text(UIFormat.displayPath(model.destinationURL))
                .font(.system(size: 10))
                .foregroundStyle(Color.ykTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(model.destinationURL?.path ?? "")
            HStack(spacing: 6) {
                Button("変更…") { model.chooseDestination() }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(model.isImporting)
                    .help(model.isImporting ? "取り込み中は変更できません" : "保存先フォルダを選択")
                Button("Finderで開く") { model.revealDestination() }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(!model.isDestinationConnected)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: Capacity

    private var capacitySection: some View {
        let required = UIFormat.requiredWithMargin(model.selectedBytes)
        let available = model.availableBytes
        let insufficient = model.isDestinationConnected && model.selectedBytes > 0 && required > available
        let fraction = available > 0 ? min(1, Double(model.selectedBytes) / Double(available)) : 0
        return VStack(alignment: .leading, spacing: 6) {
            MetricRow(label: "空き容量", value: model.isDestinationConnected ? formattedBytes(available) : "—")
            MetricRow(label: "今回必要", value: formattedBytes(model.selectedBytes))
            GeometryReader { proxy in
                let barWidth: CGFloat = fraction > 0 ? max(3, proxy.size.width * CGFloat(fraction)) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.ykRaised)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(insufficient ? Color.ykCritical : Color.accentColor)
                        .frame(width: barWidth)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            if insufficient {
                StatusLabel(symbol: "exclamationmark.triangle.fill", text: "空き容量が不足しています。余裕を含め\(formattedBytes(required))必要です。",
                            tint: .ykCritical, textColor: .ykPrimary, fontSize: 10)
            } else if model.selectedBytes > 0 {
                Text("余裕分を含む必要量 \(formattedBytes(required))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ykTertiary)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    // MARK: Date tree

    @ViewBuilder private func dateTree(_ years: [DateTreeYear], selections: [String: DateSelectionSummary]) -> some View {
        if years.isEmpty {
            Text(emptyTreeMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color.ykTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(years) { year in
                    yearRow(year)
                    if isExpanded(year) {
                        ForEach(year.days) { day in dayRow(day, selection: selections[day.path]) }
                    }
                }
            }
        }
    }

    private var emptyTreeMessage: String {
        if model.isScanning { return "照合が終わると、日付ごとの追加予定件数を表示します。" }
        if model.items.isEmpty { return "取り込み対象はまだありません。" }
        return "日付フォルダはありません。"
    }

    private func isExpanded(_ year: DateTreeYear) -> Bool {
        yearExpansionOverrides[year.year] ?? (year.hasSelectableItems || year.count > 0)
    }

    private func yearRow(_ year: DateTreeYear) -> some View {
        let collapsed = !isExpanded(year)
        return Button {
            yearExpansionOverrides[year.year] = collapsed
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(Color.ykTertiary)
                    .frame(width: 10)
                Text(year.year)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ykPrimary)
                Spacer(minLength: 4)
                plannedCount(year.count)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(year.count > 0 ? "\(year.year)年、追加予定\(year.count)件" : "\(year.year)年")
        .accessibilityValue(collapsed ? "折りたたみ" : "展開")
        .accessibilityHint("日付の一覧を開閉します")
    }

    private func dayRow(_ day: FolderSummary, selection: DateSelectionSummary?) -> some View {
        let parts = UIFormat.splitFolder(day.path)
        let isDateFolder = parts.year != parts.day
        let isActive = model.dateFilter == day.path
        return HStack(spacing: 6) {
            if let selection, selection.total > 0 {
                DateSelectionCheckbox(
                    state: selection.isAllSelected ? .on : (selection.isPartiallySelected ? .mixed : .off),
                    enabled: !model.isBusy,
                    title: "\(day.path)をまとめて選択",
                    action: { model.selectDate(day.path, selected: !selection.isAllSelected) }
                )
                .frame(width: 16, height: 16)
            } else {
                Image(systemName: day.isNew && day.count > 0 ? "folder.badge.plus" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ykTertiary)
                    .frame(width: 16)
            }
            Button {
                if !isDateFolder {
                    model.dateFilter = nil
                    model.filter = .attention
                } else {
                    model.dateFilter = isActive ? nil : day.path
                }
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(isDateFolder ? parts.day : day.path)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color.ykPrimary)
                            if day.isNew && day.count > 0 {
                                Text("新規")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.ykSecondary)
                            }
                        }
                        if day.count > 0 {
                            Text(breakdown(day))
                                .font(.system(size: 10))
                                .foregroundStyle(Color.ykTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    plannedCount(day.count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isActive ? "絞り込みを解除" : "\(day.path)で絞り込み")
            .accessibilityLabel(accessibilityText(day, isDateFolder: isDateFolder))
            .accessibilityValue(isActive ? "絞り込み中" : "")
            .accessibilityAddTraits(isActive ? .isSelected : [])
        }
        .padding(.leading, 30)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .background(isActive ? Color.ykRowSelection : Color.clear)
        .overlay(alignment: .leading) {
            if isActive { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
    }

    @ViewBuilder private func plannedCount(_ count: Int) -> some View {
        if count > 0 {
            Text("+\(count.formatted())件")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.ykPrimary)
        }
    }

    private func breakdown(_ day: FolderSummary) -> String {
        var parts: [String] = []
        if day.photos > 0 { parts.append("写真\(day.photos)") }
        if day.videos > 0 { parts.append("動画\(day.videos)") }
        parts.append(formattedBytes(day.bytes))
        return parts.joined(separator: " · ")
    }

    private func accessibilityText(_ day: FolderSummary, isDateFolder: Bool) -> String {
        var text = isDateFolder ? "\(day.path.replacingOccurrences(of: "/", with: "年 ").replacingOccurrences(of: "-", with: "月"))日" : day.path
        if day.isNew && day.count > 0 { text += "、新規フォルダ" }
        if day.count > 0 { text += "、追加予定\(day.count)件、写真\(day.photos)件、動画\(day.videos)件、\(formattedBytes(day.bytes))" }
        return text
    }

    // MARK: Plan summary

    private func planSummary(_ summaries: [FolderSummary]) -> some View {
        let newFolders = summaries.filter { $0.isNew && $0.count > 0 }.count
        return VStack(alignment: .leading, spacing: 5) {
            MetricRow(label: "写真・RAW", value: UIFormat.count(model.selectedPhotoCount), symbol: "photo")
            MetricRow(label: "動画", value: UIFormat.count(model.selectedVideoCount), symbol: "film")
            MetricRow(label: "付随ファイル", value: UIFormat.count(model.selectedSidecarCount), symbol: "paperclip")
            MetricRow(label: "新規フォルダ", value: UIFormat.count(newFolders), symbol: "folder.badge.plus")
            MetricRow(label: "予定容量", value: formattedBytes(model.selectedBytes), symbol: "internaldrive")
            if model.selectedSidecarCount > 0 {
                Text("付随ファイルは件数に含めず、容量には含めています。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ykTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.dateFilter != nil {
                Button("日付の絞り込みを解除") { model.dateFilter = nil }
                    .buttonStyle(FlatButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
    }
}

/// Use the system checkbox so partial selection has the native mixed state.
private struct DateSelectionCheckbox: NSViewRepresentable {
    var state: NSControl.StateValue
    var enabled: Bool
    var title: String
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.controlSize = .small
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = state
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.toolTip = state == .on ? "すべて解除" : "すべて選択"
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
