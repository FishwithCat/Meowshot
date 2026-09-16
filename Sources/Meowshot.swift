import AppKit
import Carbon
import UniformTypeIdentifiers

enum CaptureMode: CaseIterable {
    case region, window, screen

    var arguments: [String] {
        switch self {
        case .region: return ["-i", "-s"]
        case .window: return ["-i", "-w"]
        case .screen: return ["-m"]
        }
    }

    func command(output: URL) -> [String] {
        ["-x", "-t", "png"] + arguments + [output.path]
    }
}

struct CapturePermission {
    enum Action { case capture, request, settings }
    private var requested = false

    mutating func action(granted: Bool) -> Action {
        if granted { return .capture }
        if requested { return .settings }
        requested = true
        return .request
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var capture: Process?
    private var preview: NSWindow?
    private var imageData: Data?
    private var captureItems: [NSMenuItem] = []
    private var permission = CapturePermission()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Meowshot 截屏")
        statusItem.button?.toolTip = "Meowshot · ⌘⇧X 截屏"
        let menu = NSMenu()
        for (title, action) in [
            ("区域截屏    ⌘⇧X", #selector(captureRegion)),
            ("窗口截屏", #selector(captureWindow)),
            ("全屏截屏（主显示器）", #selector(captureScreen))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            captureItems.append(item)
        }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let permission = NSMenuItem(title: "屏幕录制权限设置…", action: #selector(openPermissions), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Meowshot", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.captureRegion() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey),
                                        EventHotKeyID(signature: 0x4D454F57, id: 1),
                                        GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            captureItems[0].title = "区域截屏（快捷键被占用）"
            showError("⌘⇧X 注册失败，请使用菜单栏开始截屏。")
        }
    }

    @objc private func captureRegion() { startCapture(.region) }
    @objc private func captureWindow() { startCapture(.window) }
    @objc private func captureScreen() { startCapture(.screen) }

    private func startCapture(_ mode: CaptureMode) {
        guard capture == nil else { return }
        switch permission.action(granted: CGPreflightScreenCaptureAccess()) {
        case .capture:
            break
        case .request:
            // Do not cover the system consent dialog with another modal alert.
            guard CGRequestScreenCaptureAccess() else { return }
        case .settings:
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = "请在系统设置中允许 Meowshot 录制屏幕。若已开启仍无法截屏，请退出并重新打开当前 App；若重新构建过 App，请在权限列表中移除旧条目，再添加当前 App。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openPermissions() }
            return
        }
        preview?.orderOut(nil)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("Meowshot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = mode.command(output: output)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: output) }
                self.capture = nil
                self.captureItems.forEach { $0.isEnabled = true }
                if let data = try? Data(contentsOf: output), let image = NSImage(data: data) {
                    self.imageData = data
                    self.showPreview(image)
                } else if mode == .screen || FileManager.default.fileExists(atPath: output.path) {
                    self.showError("未能获取截图，请检查屏幕录制权限后重试。")
                } else {
                    // screencapture produces no file when an interactive capture is cancelled.
                    self.preview?.makeKeyAndOrderFront(nil)
                }
            }
        }
        capture = process
        captureItems.forEach { $0.isEnabled = false }
        // Let the menu and preview disappear before capturing the display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            do { try process.run() }
            catch {
                self.capture = nil
                self.captureItems.forEach { $0.isEnabled = true }
                self.showError(error.localizedDescription)
            }
        }
    }

    private func showPreview(_ image: NSImage) {
        preview?.close()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Meowshot · 截图预览"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 280)
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("截图预览")
        let copy = NSButton(title: "复制  ⌘C", target: self, action: #selector(copyImage))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = NSButton(title: "保存 PNG…", target: self, action: #selector(saveImage))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views: [copy, save])
        buttons.spacing = 12
        let content = window.contentView!
        for view in [imageView, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        preview = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func copyImage() {
        guard let imageData else { return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setData(imageData, forType: .png) {
            showError("复制失败，请重试或保存为文件。")
        }
    }

    @objc private func saveImage() {
        guard let imageData, let preview else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "Meowshot \(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: preview) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try imageData.write(to: url, options: .atomic) }
            catch { self.showError("保存失败：\(error.localizedDescription)") }
        }
    }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quitApp() {
        capture?.terminate()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Meowshot"
        alert.informativeText = message
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--self-test") {
    var permission = CapturePermission()
    precondition(permission.action(granted: false) == .request)
    precondition(permission.action(granted: false) == .settings)
    precondition(permission.action(granted: true) == .capture)
    precondition(permission.action(granted: false) == .settings)
    var authorized = CapturePermission()
    precondition(authorized.action(granted: true) == .capture)
    precondition(authorized.action(granted: false) == .request)
    let output = URL(fileURLWithPath: "/tmp/screenshot with spaces.png")
    for mode in CaptureMode.allCases {
        let command = mode.command(output: output)
        precondition(command.last == output.path, "Output must remain a single argument")
        precondition(command.prefix(3) == ["-x", "-t", "png"])
    }
    precondition(CaptureMode.region.command(output: output) == ["-x", "-t", "png", "-i", "-s", output.path])
    precondition(CaptureMode.window.command(output: output) == ["-x", "-t", "png", "-i", "-w", output.path])
    precondition(CaptureMode.screen.command(output: output) == ["-x", "-t", "png", "-m", output.path])
    print("PASS: permission flow, screenshot modes and output paths")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
