import SwiftUI

/// Stacked notices above the grid: errors, completion, interrupted jobs and items on hold.
struct CenterNotices: View {
    @ObservedObject var model: AppModel
    var onRequestDateResolution: (MediaItem) -> Void
    @State private var confirmCleanup = false

    private var undated: [MediaItem] { model.items.filter { $0.status == .needsDate } }
    private var failedCount: Int { model.items.filter { $0.status == .failed }.count }

    var body: some View {
        VStack(spacing: 1) {
            if let error = model.errorMessage {
                NoticeBanner(.error, title: "処理を続けられませんでした", message: error) {
                    Button("閉じる") { model.dismissError() }.buttonStyle(FlatButtonStyle())
                }
            }
            if let completion = model.completionMessage, !model.isBusy {
                NoticeBanner(failedCount > 0 ? .warning : .success, title: completion,
                             message: failedCount > 0 ? "失敗 \(failedCount)件。理由を確認し、再読み込みで再計画できます。" : "確定済みのファイルは保存先で内容を検証済みです。元のファイルは残っています。") {
                    Button("保存先を開く") { model.revealDestination() }.buttonStyle(FlatButtonStyle())
                    if failedCount > 0 {
                        Button("失敗を確認") { model.dateFilter = nil; model.filter = .attention }.buttonStyle(FlatButtonStyle())
                    }
                }
            }
            if model.pendingRecoveryCount > 0 && !model.isBusy {
                NoticeBanner(.warning, title: "中断した取り込みが\(model.pendingRecoveryCount)件あります",
                             message: "確定済みのファイルはそのまま残っています。再読み込みで未完了分を再照合できます。途中ファイルの片付けは、本アプリが作成したと記録で確認できたものだけが対象です。") {
                    Button("再読み込み") { model.refresh() }.buttonStyle(FlatButtonStyle())
                    Button("途中ファイルを片付ける…") { confirmCleanup = true }.buttonStyle(FlatButtonStyle())
                }
                .confirmationDialog("途中ファイルを片付けますか？", isPresented: $confirmCleanup) {
                    Button("片付ける", role: .destructive) { model.clearRecovery() }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("保存先に残った本アプリの一時ファイルだけを削除します。確定済みの写真・動画や、他のアプリ・ユーザーのファイルには触れません。")
                }
            }
            if !model.isBusy && !undated.isEmpty {
                NoticeBanner(.warning, title: "撮影日時を確認できない項目が\(undated.count)件あります",
                             message: "保存先の日付を決められないため保留しています。日時を指定するか、ファイル更新日時を使うと取り込み対象にできます。") {
                    Button("表示") { model.dateFilter = nil; model.filter = .attention }.buttonStyle(FlatButtonStyle())
                    if let first = undated.first {
                        Button("日時を指定…") { onRequestDateResolution(first) }.buttonStyle(FlatButtonStyle())
                    }
                }
            }
            if !model.isSourceConnected && !model.items.isEmpty {
                NoticeBanner(.warning, title: "取り込み元が取り外されたか、アクセスできません",
                             message: "表示中の一覧は最後に照合した内容です。再接続すると自動で再照合します。")
            } else if !model.isDestinationConnected && !model.items.isEmpty {
                NoticeBanner(.warning, title: "保存先が取り外されたか、アクセスできません",
                             message: "保存先が戻るまで照合と取り込みは開始しません。")
            }
        }
        .background(Color.ykSeparator)
    }
}

/// Full-area message when the grid has nothing to show. Each case offers the next useful action.
struct GridEmptyState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.visibleItems.isEmpty {
            content
                .frame(maxWidth: 420)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.ykGrid)
        }
    }

    @ViewBuilder private var content: some View {
        if model.sourceURL == nil || (!model.isSourceConnected && model.items.isEmpty) {
            message(symbol: "sdcard", title: "取り込み元が接続されていません",
                    detail: "カードを挿入するか、写真・動画のあるフォルダを選択してください。接続されると自動で一覧を作成します。") {
                Button("取り込み元を選択…") { model.chooseSource() }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .disabled(model.isImporting)
                let candidates = model.volumes.filter(\.isRemovable)
                if !candidates.isEmpty {
                    VStack(spacing: 4) {
                        Text("接続中のカード").font(.system(size: 11)).foregroundStyle(Color.ykTertiary)
                        ForEach(candidates) { volume in
                            Button(volume.name) { model.selectSourceVolume(volume.url) }
                                .buttonStyle(FlatButtonStyle())
                                .help(volume.url.path)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else if model.destinationURL == nil || (!model.isDestinationConnected && model.items.isEmpty) {
            message(symbol: "externaldrive.badge.questionmark", title: "保存先が見つかりません",
                    detail: "保存先のドライブを接続するか、保存先フォルダを選択してください。保存先が確認できるまで照合と取り込みは開始しません。") {
                Button("保存先を選択…") { model.chooseDestination() }
                    .buttonStyle(FlatButtonStyle(prominent: true))
                    .disabled(model.isImporting)
            }
        } else if model.isScanning && model.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text(model.statusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.ykSecondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        } else if model.items.isEmpty {
            message(symbol: "photo.on.rectangle.angled", title: "写真・動画が見つかりません",
                    detail: model.sourceMode == .camera ? "探索フォルダ（DCIM・CLIP）に対応する形式のファイルがありません。設定で探索方式やフォルダを確認してください。" : "選択したフォルダ配下に対応する形式のファイルがありません。") {
                Button("再読み込み") { model.refresh() }
                    .buttonStyle(FlatButtonStyle())
                    .disabled(model.isBusy)
            }
        } else {
            message(symbol: "line.3.horizontal.decrease.circle", title: "この絞り込みに該当する項目はありません",
                    detail: "絞り込みを変えても、選択状態はそのまま保持されます。") {
                Button("絞り込みを解除") {
                    model.filter = .all
                    model.kindFilter = .all
                    model.dateFilter = nil
                }
                .buttonStyle(FlatButtonStyle())
            }
        }
    }

    private func message<Actions: View>(symbol: String, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.ykTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ykPrimary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.ykSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) { actions() }
                .padding(.top, 4)
        }
    }
}
