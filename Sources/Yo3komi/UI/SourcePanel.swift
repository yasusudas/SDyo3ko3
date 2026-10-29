import SwiftUI
import AppKit

/// One pass over the scanned items for the left column's counters.
struct SourceStats {
    var photos = 0, raws = 0, videos = 0, sidecars = 0
    var new = 0, imported = 0, duplicates = 0, attention = 0, checking = 0

    init(_ items: [MediaItem]) {
        for item in items {
            switch item.kind {
            case .photo: photos += 1
            case .raw: raws += 1
            case .video: videos += 1
            case .sidecar: break
            }
            sidecars += item.related.count
            switch item.status {
            case .new: new += 1
            case .imported: imported += 1
            case .cardDuplicate: duplicates += 1
            case .needsDate, .failed: attention += 1
            case .checking: checking += 1
            case .copying, .verifying: break
            }
        }
    }
}

struct SourcePanel: View {
    @ObservedObject var model: AppModel
    @State private var dcimExists: Bool?
    @State private var clipExists: Bool?

    private var sourceName: String {
        UIFormat.volumeName(of: model.sourceURL) ?? model.sourceURL?.lastPathComponent ?? "未設定"
    }

    var body: some View {
        let stats = SourceStats(model.items)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader("取り込み元")
                sourceCard
                PanelHeader("探索フォルダ")
                foldersSection
                PanelHeader("接続中のボリューム") {
                    SymbolButton(symbol: "arrow.clockwise", help: "ボリューム一覧を更新") { model.refreshVolumes() }
                }
                volumesSection
                PanelHeader("検出件数")
                countsSection(stats)
                if !model.warnings.isEmpty {
                    PanelHeader("注意")
                    warningsSection
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .panelBackground()
        .task(id: folderProbeKey) { await probeFolders() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("取り込み元")
    }

    // MARK: Source card

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.sourceMode == .camera ? "sdcard" : "folder")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.ykSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ykPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.sourceMode.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ykSecondary)
                }
            }
            .help(model.sourceURL?.path ?? "未設定")
            ConnectionLabel(state: model.sourceConnectionState)
            Text(UIFormat.displayPath(model.sourceURL))
                .font(.system(size: 10))
                .foregroundStyle(Color.ykTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(model.sourceURL?.path ?? "")
            Button("変更…") { model.chooseSource() }
                .buttonStyle(FlatButtonStyle())
                .disabled(model.isImporting)
                .help(model.isImporting ? "取り込み中は変更できません" : "監視するカードまたはフォルダを選択")
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
    }

    // MARK: Folders

    private var folderProbeKey: String {
        "\(model.sourceURL?.path ?? "")|\(model.isSourceConnected)|\(model.sourceMode.rawValue)|\(model.isScanning)"
    }

    private func probeFolders() async {
        guard let root = model.sourceURL, model.isSourceConnected, model.sourceMode == .camera else {
            dcimExists = nil; clipExists = nil; return
        }
        let result = await Task.detached(priority: .utility) { () -> (Bool, Bool) in
            let fm = FileManager.default
            return (fm.fileExists(atPath: root.appendingPathComponent("DCIM").path),
                    fm.fileExists(atPath: root.appendingPathComponent("PRIVATE/M4ROOT/CLIP").path))
        }.value
        guard !Task.isCancelled else { return }
        dcimExists = result.0
        clipExists = result.1
    }

    @ViewBuilder private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.sourceMode == .camera {
                folderToggle("DCIM", detail: "写真", isOn: $model.includeDCIM, exists: dcimExists)
                folderToggle("CLIP", detail: "PRIVATE/M4ROOT/CLIP・動画", isOn: $model.includeCLIP, exists: clipExists)
                if !model.includeDCIM && !model.includeCLIP {
                    StatusLabel(symbol: "exclamationmark.triangle.fill", text: "探索フォルダがありません",
                                tint: .ykCaution, textColor: .ykPrimary)
                }
            } else {
                Label("選択したフォルダ配下をすべて検索", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ykSecondary)
            }
        }
        .padding(.horizontal, 14)
        .disabled(model.isImporting)
    }

    private func folderToggle(_ title: String, detail: String, isOn: Binding<Bool>, exists: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: isOn) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ykPrimary)
            }
            .toggleStyle(.checkbox)
            .onChange(of: isOn.wrappedValue) { model.settingsChanged() }
            Group {
                if exists == false {
                    StatusLabel(symbol: "questionmark.folder", text: "このカードにはありません",
                                tint: .ykCaution, textColor: .ykSecondary, fontSize: 10)
                } else {
                    Text(detail).font(.system(size: 10)).foregroundStyle(Color.ykTertiary)
                }
            }
            .padding(.leading, 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(exists == false ? "\(title)フォルダはこのカードにありません" : "オンにすると走査対象に含めます")
    }

    // MARK: Volumes

    @ViewBuilder private var volumesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.volumes.isEmpty {
                Text("外部ボリュームはありません")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ykTertiary)
                    .padding(.horizontal, 14)
            }
            ForEach(model.volumes) { volume in
                VolumeRow(volume: volume,
                          role: role(of: volume),
                          disabled: model.isImporting || role(of: volume) == .destination) {
                    model.selectSourceVolume(volume.url)
                }
            }
        }
    }

    private func role(of volume: VolumeInfo) -> VolumeRow.Role {
        let path = volume.url.standardizedFileURL.path
        func contains(_ url: URL?) -> Bool {
            guard let other = url?.standardizedFileURL.path else { return false }
            return other == path || other.hasPrefix(path.hasSuffix("/") ? path : path + "/")
        }
        if contains(model.destinationURL) { return .destination }
        if contains(model.sourceURL) { return .source }
        return .candidate
    }

    // MARK: Counts

    private func countsSection(_ stats: SourceStats) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    if model.scanTotal > 0 {
                        ProgressView(value: Double(min(model.scanCompleted, model.scanTotal)), total: Double(model.scanTotal))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    Text(model.statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ykSecondary)
                        .lineLimit(3)
                }
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
            }
            MetricRow(label: "RAW", value: UIFormat.count(stats.raws), symbol: "camera.aperture")
            MetricRow(label: "写真", value: UIFormat.count(stats.photos), symbol: "photo")
            MetricRow(label: "動画", value: UIFormat.count(stats.videos), symbol: "film")
            MetricRow(label: "付随ファイル", value: UIFormat.count(stats.sidecars), symbol: "paperclip")
            Divider().overlay(Color.ykSeparator).padding(.vertical, 3)
            MetricRow(label: "未取り込み", value: UIFormat.count(stats.new), symbol: "arrow.down.circle")
            MetricRow(label: "取り込み済み", value: UIFormat.count(stats.imported), symbol: "checkmark.circle")
            if stats.duplicates > 0 {
                MetricRow(label: "カード内同一", value: UIFormat.count(stats.duplicates), symbol: "square.on.square")
            }
            if stats.attention > 0 {
                MetricRow(label: "要確認", value: UIFormat.count(stats.attention), symbol: "exclamationmark.triangle.fill", symbolColor: .ykCaution)
            }
            if stats.checking > 0 {
                MetricRow(label: "照合中", value: UIFormat.count(stats.checking), symbol: "hourglass")
            }
        }
        .padding(.horizontal, 14)
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ykCaution).font(.system(size: 10)).padding(.top, 2)
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ykSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("注意: \(warning)")
            }
        }
        .padding(.horizontal, 14)
    }
}

struct VolumeRow: View {
    enum Role { case source, destination, candidate }
    var volume: VolumeInfo
    var role: Role
    var disabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            if role == .candidate { action() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: volume.isRemovable ? "sdcard" : "externaldrive")
                    .font(.system(size: 12))
                    .foregroundStyle(role == .source ? Color.accentColor : Color.ykSecondary)
                    .frame(width: 16)
                Text(volume.name)
                    .font(.system(size: 12, weight: role == .source ? .semibold : .regular))
                    .foregroundStyle(Color.ykPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                switch role {
                case .source: roleCaption("取り込み元", color: .ykSecondary)
                case .destination: roleCaption("保存先", color: .ykTertiary)
                case .candidate: EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(role == .source ? Color.ykRowSelection : (hovering && !disabled ? Color.ykRaised : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel("\(volume.name)、\(roleText)")
        .accessibilityHint(role == .candidate ? "取り込み元として選択します" : "")
    }

    /// Plain trailing role text; the row itself (selection background, weight) marks the source.
    private func roleCaption(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var roleText: String {
        switch role {
        case .source: return "現在の取り込み元"
        case .destination: return "保存先のため取り込み元にできません"
        case .candidate: return volume.isRemovable ? "取り外し可能なボリューム" : "外部ボリューム"
        }
    }

    private var helpText: String {
        switch role {
        case .source: return volume.url.path
        case .destination: return "保存先を含むボリュームは取り込み元にできません"
        case .candidate: return "クリックで取り込み元に設定し、アクセスを許可します（\(volume.url.path)）"
        }
    }
}
