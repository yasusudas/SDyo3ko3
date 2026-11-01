import AppKit

/// Translate generated menu labels in place, preserving SwiftUI's commands and responder chain.
@MainActor
final class MenuLocalizer {
    static let shared = MenuLocalizer()

    private let translations: [String: String]
    private let applicationNames: Set<String>
    private var observers: [NSObjectProtocol] = []
    private var isLocalizing = false
    private var passScheduled = false

    init(bundle: Bundle = .main) {
        let url = bundle.url(forResource: "MenuLocalizable", withExtension: "strings", subdirectory: "ja.lproj")
        if let url, let data = try? Data(contentsOf: url),
           let table = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
            translations = table
        } else { translations = [:] }
        applicationNames = Set(["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"].compactMap {
            bundle.object(forInfoDictionaryKey: $0) as? String
        } + [ProcessInfo.processInfo.processName, "yo3komi"])
    }

    func start() {
        guard observers.isEmpty else { localizeMainMenu(); return }
        let center = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                     NSMenu.didBeginTrackingNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, !self.isLocalizing else { return }
                    if let menu = note.object as? NSMenu, self.belongsToMainMenu(menu) {
                        self.localize(menu: menu)
                    }
                    if name == NSMenu.didBeginTrackingNotification {
                        self.localizeMainMenu()
                    } else { self.schedulePass() }
                }
            })
        }
        localizeMainMenu()
        schedulePass()
    }

    func localizeMainMenu() {
        guard let menu = NSApp.mainMenu else { return }
        localize(menu: menu)
    }

    func localize(menu: NSMenu) {
        guard !isLocalizing, !translations.isEmpty else { return }
        isLocalizing = true
        defer { isLocalizing = false }
        translate(menu: menu)
    }

    private func schedulePass() {
        guard !passScheduled else { return }
        passScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.passScheduled = false
            self.localizeMainMenu()
        }
    }

    private func belongsToMainMenu(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let ancestor = current {
            if ancestor === NSApp.mainMenu { return true }
            current = ancestor.supermenu
        }
        return false
    }

    private func translate(menu: NSMenu) {
        if let title = localizedTitle(menu.title), title != menu.title { menu.title = title }
        for item in menu.items where !item.isSeparatorItem {
            let original = item.title
            if let title = localizedTitle(original, action: item.action), title != original {
                if let attributed = item.attributedTitle, attributed.string == original {
                    let updated = NSMutableAttributedString(attributedString: attributed)
                    updated.replaceCharacters(in: NSRange(location: 0, length: updated.length), with: title)
                    item.attributedTitle = updated
                }
                item.title = title
            }
            if let tooltip = item.toolTip, let title = localizedTitle(tooltip), title != tooltip { item.toolTip = title }
            if let submenu = item.submenu { translate(menu: submenu) }
        }
    }

    private func localizedTitle(_ title: String, action: Selector? = nil) -> String? {
        let normalized = title.replacingOccurrences(of: "...", with: "…")
        if let value = translations[title] ?? translations[normalized] { return value }
        // Keep user-specific display/device names while translating the system command around them.
        let selector = action.map(NSStringFromSelector) ?? ""
        if selector.hasPrefix("_move") || selector == "_toggleIPad:" {
            for (prefix, key) in [("Move All to ", "Move All to %@"), ("Move to ", "Move to %@")] {
                if normalized.hasPrefix(prefix), let format = translations[key] {
                    return format.replacingOccurrences(of: "%@", with: String(normalized.dropFirst(prefix.count)))
                }
            }
        }
        // Application names and document/window titles are proper names, never translated as arbitrary text.
        for name in applicationNames {
            for (key, value) in [("About \(name)", "\(name)について"),
                                 ("Hide \(name)", "\(name)を非表示"),
                                 ("Quit \(name)", "\(name)を終了"),
                                 ("\(name) Help", "\(name)ヘルプ"),
                                 ("Quit \(name) and Keep Windows", "\(name)を終了してウインドウを保持"),
                                 ("Quit \(name) and Close All Windows", "\(name)を終了してすべてのウインドウを閉じる")] {
                if normalized == key { return value }
            }
        }
        return nil
    }
}
