import SwiftUI

/// Settings window (⌘,). Every change is written to the model and reported through
/// `settingsChanged()`; the model persists, debounces and re-plans when needed.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            ImportSettingsTab(model: model)
                .tabItem { Label("取り込み", systemImage: "sdcard") }
            DateSettingsTab(model: model)
                .tabItem { Label("撮影日時", systemImage: "calendar") }
            DisplaySettingsTab(model: model)
                .tabItem { Label("表示", systemImage: "paintbrush") }
            MaintenanceSettingsTab(model: model)
                .tabItem { Label("照合と復旧", systemImage: "checkmark.shield") }
            HistorySettingsTab(model: model)
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 560)
        .scenePadding()
        .preferredColorScheme(model.appearance == "system" ? nil : (model.appearance == "light" ? .light : .dark))
    }
}

private struct SettingsNote: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LocationRow: View {
    var title: String
    var url: URL?
    var state: ConnectionState
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(url?.path ?? "未設定")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(url?.path ?? "")
                HStack(spacing: 10) {
                    // The path line already reads 未設定 when nothing is chosen.
                    if state != .unconfigured {
                        ConnectionLabel(state: state)
                    }
                    Button("変更…", action: action)
                        .disabled(disabled)
                }
            }
        }
    }
}

// MARK: - Tabs

private struct ImportSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("取り込み元") {
                LocationRow(title: "場所", url: model.sourceURL, state: model.sourceConnectionState, disabled: model.isImporting) { model.chooseSource() }
                Picker("探索方式", selection: $model.sourceMode) {
                    ForEach(SourceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.radioGroup)
                Toggle("DCIM（写真）を含める", isOn: $model.includeDCIM)
                    .disabled(model.sourceMode != .camera)
                Toggle("PRIVATE/M4ROOT/CLIP（動画）を含める", isOn: $model.includeCLIP)
                    .disabled(model.sourceMode != .camera)
                SettingsNote(text: model.sourceMode == .camera
                             ? "カメラカード方式は、カード直下の DCIM と PRIVATE/M4ROOT/CLIP を再帰的に探索します。片方がない場合も、ある側だけを表示します。"
                             : "通常フォルダ方式は、選択したフォルダ配下をすべて探索します。シンボリックリンクや別ボリュームはたどりません。")
            }
            Section("保存先") {
                LocationRow(title: "場所", url: model.destinationURL, state: model.destinationConnectionState, disabled: model.isImporting) { model.chooseDestination() }
                SettingsNote(text: "保存先の配下全体と取り込み履歴を、ファイル内容（SHA-256）で照合します。動画は音声・映像データのハッシュでも照合します。履歴は保持されるため、保存先から削除・移動したファイルも再取り込みしません。新しいファイルは 年/月-日/元のファイル名 に保存します。")
            }
            if model.isImporting {
                SettingsNote(text: "取り込み中は取り込み元・保存先・探索設定を変更できません。")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isImporting)
        .onChange(of: model.sourceMode) { model.settingsChanged() }
        .onChange(of: model.includeDCIM) { model.settingsChanged() }
        .onChange(of: model.includeCLIP) { model.settingsChanged() }
    }
}

private struct DateSettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var query = ""

    private static let identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Self.identifiers }
        return Self.identifiers.filter { $0.localizedCaseInsensitiveContains(q) || label(for: $0).localizedCaseInsensitiveContains(q) }
    }

    private var zoneSelection: Binding<String?> {
        Binding<String?>(
            get: { Optional(model.timeZoneID) },
            set: { value in
                if let value, value != model.timeZoneID { model.timeZoneID = value }
            })
    }

    private func label(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = zone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let hours = abs(seconds) / 3600, minutes = (abs(seconds) % 3600) / 60
        let name = zone.localizedName(for: .generic, locale: Locale(identifier: "ja_JP")) ?? ""
        return String(format: "%@（GMT%@%02d:%02d）%@", identifier, sign, hours, minutes, name.isEmpty ? "" : " " + name)
    }

    var body: some View {
        Form {
            Section("撮影地のタイムゾーン") {
                LabeledContent("現在の設定") {
                    Text(label(for: model.timeZoneID)).textSelection(.enabled)
                }
                TextField("検索（例: Tokyo, Paris）", text: $query)
                    .textFieldStyle(.roundedBorder)
                List(matches, id: \.self, selection: zoneSelection) { identifier in
                    Text(label(for: identifier))
                        .font(.system(size: 12))
                        .tag(identifier)
                }
                .frame(height: 180)
                .accessibilityLabel("タイムゾーン一覧")
                HStack {
                    Button("このMacのタイムゾーンを使う") { model.timeZoneID = TimeZone.current.identifier }
                    Button("Asia/Tokyo に戻す") { model.timeZoneID = "Asia/Tokyo" }
                }
                SettingsNote(text: "撮影現地のカレンダー日で仕分けます。時差情報（オフセット）を持つ写真はその値を優先し、UTCだけが記録された動画などの日付を決めるときにこのタイムゾーンを使います。変更すると再照合します。元ファイルやEXIFは変更しません。")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isImporting)
        .onChange(of: model.timeZoneID) { model.settingsChanged() }
    }
}

private struct DisplaySettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("外観") {
                Picker("テーマ", selection: $model.appearance) {
                    Text("ダーク").tag("dark")
                    Text("ライト").tag("light")
                    Text("システムに合わせる").tag("system")
                }
                .pickerStyle(.radioGroup)
                SettingsNote(text: "写真そのものには色の補正やフィルタをかけません。")
            }
            Section("サムネイル") {
                LabeledContent("大きさ") {
                    HStack {
                        Slider(value: $model.thumbnailSize, in: 120...360, step: 10, onEditingChanged: { editing in
                            if !editing { model.settingsChanged() }
                        })
                        .frame(width: 220)
                        Text("\(Int(model.thumbnailSize)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                SettingsNote(text: "サムネイルは表示中の項目だけを生成します。RAWは埋め込みプレビューを優先します。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.appearance) { model.settingsChanged() }
    }
}

private struct MaintenanceSettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var confirmCleanup = false

    var body: some View {
        Form {
            Section("内容の照合") {
                LabeledContent("内容を再検証") {
                    Button("フルハッシュで再照合") { model.refresh(force: true) }
                        .disabled(model.isBusy)
                }
                SettingsNote(text: "通常はファイル属性で変更を検出して索引を再利用します。サイズや日時を保ったまま外部で書き換えられた可能性がある場合は、キャッシュを使わず全内容を読み直します。時間がかかります。取り込み履歴は消去しません。")
            }
            Section("中断した取り込み") {
                LabeledContent("未完了のジョブ") {
                    Text(model.pendingRecoveryCount == 0 ? "なし" : "\(model.pendingRecoveryCount)件")
                        .monospacedDigit()
                }
                LabeledContent("途中ファイル") {
                    Button("片付ける…") { confirmCleanup = true }
                        .disabled(model.isBusy || model.pendingRecoveryCount == 0)
                }
                SettingsNote(text: "本アプリが作成したと記録で確認できる一時ファイルだけを削除します。確定済みのファイルと、他のアプリやユーザーのファイルには触れません。")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("途中ファイルを片付けますか？", isPresented: $confirmCleanup) {
            Button("片付ける", role: .destructive) { model.clearRecovery() }
            Button("キャンセル", role: .cancel) {}
        }
    }
}

/// Counts, export and import of the persistent import history. File panels, validation and the
/// merge itself belong to the model; this tab only reports counts and the last result.
private struct HistorySettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("取り込み履歴") {
                LabeledContent("記録したファイル") {
                    Text("\(model.historyRecordCount.formatted())件")
                        .monospacedDigit()
                }
                LabeledContent("音声・映像ハッシュのある動画") {
                    Text("\(model.videoHistoryCount.formatted())件")
                        .monospacedDigit()
                }
                SettingsNote(text: "音声・映像ハッシュのない以前の記録も、ファイル全体の SHA-256 でそのまま照合に使います。")
            }
            Section("書き出しと読み込み") {
                LabeledContent("履歴ファイル") {
                    HStack {
                        Button("書き出す…") { model.exportHistory() }
                        Button("読み込む…") { model.importHistory() }
                    }
                    .disabled(model.isBusy)
                }
                if model.isManagingHistory {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("履歴を処理しています…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if let message = model.historyMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsNote(text: "JSON 形式です。ファイル名、取り込み元と保存先のパス、ファイル全体の SHA-256、動画の音声・映像ハッシュを含みます。写真・動画そのものや編集データは含みません。")
                SettingsNote(text: "読み込んだ履歴は現在の履歴に足し合わせます。同じ内容の記録は1件にまとめ、既存の記録は消しません。保存先の写真・動画は変更せず、読み込み後に一覧を再照合します。")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshHistorySummary() }
    }
}
