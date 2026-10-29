import SwiftUI
import AppKit

@main
struct Yo3komiApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model=AppModel()
    var body:some Scene {
        Window("yo3komi",id:"main") {
            AppRoot(model:model,delegate:delegate)
                .frame(minWidth:1000,minHeight:640)
                .preferredColorScheme(model.appearance == "system" ? nil : model.appearance == "light" ? .light : .dark)
        }
        .defaultSize(width:1440,height:900)
        .commands {
            CommandGroup(replacing:.newItem) { }
            CommandGroup(after:.newItem) {
                Button("再読み込み"){model.refresh()}.keyboardShortcut("r").disabled(model.isImporting)
                Button("内容を再検証"){model.refresh(force:true)}.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(model.isBusy)
            }
        }
        Settings { SettingsView(model:model) }
    }
}
private struct AppRoot:View {
    @ObservedObject var model:AppModel
    let delegate:AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body:some View {
        MainWindowView(model:model).onAppear {delegate.reopen = {openWindow(id:"main")}}
    }
}
final class AppDelegate:NSObject,NSApplicationDelegate {
    var reopen:(()->Void)?
    func applicationDidFinishLaunching(_ notification:Notification){NSApp.setActivationPolicy(.regular)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool{
        if !hasVisibleWindows || !sender.windows.contains(where:{$0.isVisible && $0.title=="yo3komi"}) {reopen?();sender.activate(ignoringOtherApps:true)};return true
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        // Ordinary quit cancels with process exit; unfinished journals are retained for the next scan.
        return .terminateNow
    }
}
