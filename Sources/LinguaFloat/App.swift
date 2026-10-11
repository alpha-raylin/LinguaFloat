import AppKit
import Carbon
import Combine

@main enum LinguaFloatApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    private var statusItem: NSStatusItem!
    private var followItem: NSMenuItem!
    private var petItem: NSMenuItem!
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var subscriptions: Set<AnyCancellable> = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        controller.setup()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "LinguaFloat")
        let menu = NSMenu()
        for (title, action, key) in [("開啟語言助手", #selector(openPanel), ""), ("翻譯剪貼簿內容", #selector(translateClipboard), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        followItem = NSMenuItem(title: "跟隨前景視窗", action: #selector(toggleFollow), keyEquivalent: ""); followItem.target = self
        menu.addItem(followItem)
        petItem = NSMenuItem(title: "顯示桌面小幫手", action: #selector(togglePet), keyEquivalent: ""); petItem.target = self
        menu.addItem(petItem)
        menu.addItem(.separator())
        for (title, action, key) in [("設定…", #selector(settings), ","), ("開始使用…", #selector(onboarding), ""), ("結束 LinguaFloat", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        // The icon fills in while an automatic correction is waiting to be looked at; the panel itself never pops up uninvited.
        controller.$hasSuggestion.combineLatest(controller.$following, controller.$petShown).receive(on: RunLoop.main).sink { [weak self] suggestion, following, pet in
            let symbol = suggestion ? "character.bubble.fill" : (following ? "text.bubble" : "character.bubble")
            let description = suggestion ? "LinguaFloat：有新結果" : (following ? "LinguaFloat：跟隨模式" : "LinguaFloat")
            self?.statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            self?.statusItem.button?.contentTintColor = suggestion ? NSColor(Theme.accent) : nil
            self?.followItem.state = following ? .on : .off
            self?.petItem.state = pet ? .on : .off
        }.store(in: &subscriptions)
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let id = key.id
            Task { @MainActor in delegate.controller.capture(correct: id == 2) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (id, code) in [(UInt32(1), UInt32(kVK_ANSI_L)), (UInt32(2), UInt32(kVK_ANSI_C))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(optionKey | shiftKey), EventHotKeyID(signature: 0x4C464C54, id: id), GetApplicationEventTarget(), 0, &reference)
            if let reference { hotkeys.append(reference) }
            if result != noErr { controller.status = "快捷鍵被佔用；請使用選單列開啟。" }
        }
        // First run: a short setup window instead of an empty panel in the middle of the screen.
        if controller.needsSetup && !controller.settings.onboarded { controller.openOnboarding() }
    }
    /// An accessory app shows no menu bar, but AppKit still routes ⌘C/⌘V/⌘A/⌘Z through the main menu's key equivalents,
    /// so without this the editor cannot paste.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "設定…", action: #selector(settings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隱藏 LinguaFloat", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "結束 LinguaFloat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "編輯")
        for (title, action, key) in [("還原", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"), ("剪下", #selector(NSText.cut(_:)), "x"), ("拷貝", #selector(NSText.copy(_:)), "c"), ("貼上", #selector(NSText.paste(_:)), "v"), ("全選", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
    @objc func openPanel() { controller.show() }
    @objc func translateClipboard() { controller.mode = .translate; controller.useClipboard() }
    @objc func toggleFollow() { controller.following.toggle() }
    @objc func togglePet() { controller.petShown.toggle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func settings() { controller.openSettings() }
    @objc func onboarding() { controller.openOnboarding() }
    @objc func quit() { NSApp.terminate(nil) }
}
