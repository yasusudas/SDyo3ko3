import SwiftUI

/// Counts per status filter, matching AppModel.visibleItems' filter rules.
struct FilterCounts {
    var all = 0, selectable = 0, imported = 0, attention = 0

    init(_ items: [MediaItem]) {
        all = items.count
        for item in items {
            if item.canSelect { selectable += 1 }
            if item.status == .imported { imported += 1 }
            if item.status == .needsDate || item.status == .failed { attention += 1 }
        }
    }

    func count(for filter: MediaFilter) -> Int {
        switch filter {
        case .all: return all
        case .new: return selectable
        case .imported: return imported
        case .attention: return attention
        }
    }
}

struct FilterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let counts = FilterCounts(model.items)
        HStack(spacing: 10) {
            Picker("表示", selection: $model.filter) {
                ForEach(MediaFilter.allCases) { filter in
                    Text("\(filter.title) \(counts.count(for: filter).formatted())").tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("状態で絞り込み")

            if let date = model.dateFilter {
                // Plain text for the active filter; only the small clear button is interactive.
                HStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("日付")
                            .foregroundStyle(Color.ykSecondary)
                        Text(date)
                            .monospacedDigit()
                            .foregroundStyle(Color.ykPrimary)
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("日付 \(date) で絞り込み中")
                    SymbolButton(symbol: "xmark", help: "日付の絞り込みを解除（選択状態は変わりません）", pointSize: 9) {
                        model.dateFilter = nil
                    }
                }
                .fixedSize()
            }

            Spacer(minLength: 8)

            Text("\(model.visibleItems.count.formatted())件を表示")
                .font(.system(size: 11))
                .foregroundStyle(Color.ykSecondary)
                .lineLimit(1)
                .layoutPriority(-1)

            Menu {
                Picker("形式", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(model.kindFilter.title)
                    .font(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel("形式で絞り込み")
            .accessibilityValue(model.kindFilter.title)

            Menu {
                Picker("並び順", selection: $model.sortByDate) {
                    Text("撮影日時順").tag(true)
                    Text("ファイル名順").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(model.sortByDate ? "撮影日時順" : "ファイル名順", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel("並び順")
            .accessibilityValue(model.sortByDate ? "撮影日時順" : "ファイル名順")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.ykChrome)
    }
}
