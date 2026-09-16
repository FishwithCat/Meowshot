import AppKit
import Carbon
import Vision
import ImageIO

enum CaptureAction {
    case image, text

    static func confirmation(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> CaptureAction? {
        guard keyCode == 36 || keyCode == 76 else { return nil }
        return modifiers.contains(.command) ? .text : .image
    }
}

struct TextCaptureState {
    var id: UUID?

    mutating func complete(id: UUID, text: String?, pasteboard: NSPasteboard) -> Bool {
        guard self.id == id else { return false }
        self.id = nil
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

func recognizedText(in image: CGImage, request: VNRecognizeTextRequest) throws -> String {
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

struct RegionSelection {
    var rect = CGRect.zero
    private var initial = CGRect.zero
    private var anchor = CGPoint.zero
    private var moving = false
    private var edges = [Bool](repeating: false, count: 4)

    mutating func begin(at point: CGPoint) {
        initial = rect
        anchor = point
        let near = rect.insetBy(dx: -8, dy: -8).contains(point)
        edges = [abs(point.x - rect.minX) < 8, abs(point.x - rect.maxX) < 8,
                 abs(point.y - rect.minY) < 8, abs(point.y - rect.maxY) < 8].map { $0 && near && !rect.isEmpty }
        if edges[0] && edges[1] { edges[0] = point.x <= rect.midX; edges[1] = !edges[0] }
        if edges[2] && edges[3] { edges[2] = point.y <= rect.midY; edges[3] = !edges[2] }
        moving = !rect.isEmpty && !edges.contains(true) && rect.contains(point)
        if !moving && !edges.contains(true) { rect = .zero }
    }

    mutating func drag(to point: CGPoint, within bounds: CGRect) {
        let point = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                            y: min(max(point.y, bounds.minY), bounds.maxY))
        if moving {
            rect.origin = CGPoint(x: min(max(initial.minX + point.x - anchor.x, bounds.minX), bounds.maxX - initial.width),
                                  y: min(max(initial.minY + point.y - anchor.y, bounds.minY), bounds.maxY - initial.height))
        } else {
            let resizing = edges.contains(true)
            let x1 = resizing ? (edges[0] ? point.x : initial.minX) : anchor.x
            let x2 = resizing ? (edges[1] ? point.x : initial.maxX) : point.x
            let y1 = resizing ? (edges[2] ? point.y : initial.minY) : anchor.y
            let y2 = resizing ? (edges[3] ? point.y : initial.maxY) : point.y
            rect = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        }
    }

    func captureRect(desktop: CGRect, mainScreenTop: CGFloat) -> CGRect {
        CGRect(x: desktop.minX + rect.minX, y: mainScreenTop - desktop.minY - rect.maxY,
               width: rect.width, height: rect.height).integral
    }
}

func captureArguments(rect: CGRect, file: URL? = nil) -> [String] {
    (file == nil ? ["-c"] : []) + ["-x", "-t", "png", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"]
        + (file.map { [$0.path] } ?? [])
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           CaptureAction.confirmation(keyCode: event.keyCode, modifiers: event.modifierFlags) != nil {
            contentView?.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SelectionView: NSView {
    var selection = RegionSelection()
    var finish: ((CaptureAction?) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection.rect)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if !selection.rect.isEmpty {
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.rect).stroke()
            NSColor.white.setFill()
            for x in [selection.rect.minX, selection.rect.midX, selection.rect.maxX] {
                for y in [selection.rect.minY, selection.rect.midY, selection.rect.maxY] {
                    if x == selection.rect.midX && y == selection.rect.midY { continue }
                    NSBezierPath(rect: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        selection.begin(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        selection.drag(to: convert(event.locationInWindow, from: nil), within: bounds)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(nil) }
        else if let action = CaptureAction.confirmation(keyCode: event.keyCode, modifiers: event.modifierFlags),
                selection.rect.width >= 1, selection.rect.height >= 1 { finish?(action) }
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
    private var captureItem: NSMenuItem!
    private var selectionWindow: NSWindow?
    private var permission = CapturePermission()
    private var textState = TextCaptureState()
    private var recognitionRequest: VNRecognizeTextRequest?
    private var cancelHotKey: EventHotKeyRef?
    private var temporaryDirectory: URL?
    private var previousApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Meowshot 截屏")
        statusItem.button?.toolTip = "Meowshot · ⌘⇧X 截屏"
        let menu = NSMenu()
        captureItem = NSMenuItem(title: "区域截屏    ⌘⇧X", action: #selector(captureRegion), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
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
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                if id == 2 { delegate.cancelTextCapture() }
                else { delegate.captureRegion() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(cmdKey | shiftKey),
                                        EventHotKeyID(signature: 0x4D454F57, id: 1),
                                        GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            captureItem.title = "区域截屏（快捷键被占用）"
            showError("⌘⇧X 注册失败，请使用菜单栏开始截屏。")
        }
    }

    @objc private func captureRegion() {
        guard capture == nil, selectionWindow == nil, textState.id == nil else { return }
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
        guard let mainScreen = NSScreen.screens.first else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let window = SelectionWindow(contentRect: desktop, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: CGRect(origin: .zero, size: desktop.size))
        view.setAccessibilityLabel("截图选区")
        view.setAccessibilityHelp("拖动选区内部移动，拖动边缘调整大小，Return 复制图片，Command Return 复制文字，Escape 取消。")
        view.finish = { [weak self, weak view] action in
            guard let self, let view else { return }
            let region = view.selection.captureRect(desktop: desktop, mainScreenTop: mainScreen.frame.maxY)
            self.selectionWindow?.close()
            self.selectionWindow = nil
            self.previousApplication?.activate(options: .activateIgnoringOtherApps)
            self.previousApplication = nil
            if let action {
                self.takeScreenshot(rect: region, action: action)
            } else {
                self.captureItem.isEnabled = true
            }
        }
        window.contentView = view
        selectionWindow = window
        captureItem.isEnabled = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func takeScreenshot(rect: CGRect, action: CaptureAction) {
        var taskID: UUID?
        var directory: URL?
        if action == .text {
            let id = UUID()
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Meowshot-\(id.uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                captureItem.isEnabled = true
                return
            }
            directory = destination
            temporaryDirectory = destination
            taskID = id
            textState.id = id
            let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x4D454F57, id: 2),
                                             GetApplicationEventTarget(), 0, &cancelHotKey)
            if result != noErr {
                try? FileManager.default.removeItem(at: destination)
                temporaryDirectory = nil
                finishTextCapture(id: id, text: nil)
                return
            }
        }
        let file = directory?.appendingPathComponent("capture.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = captureArguments(rect: rect, file: file)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                defer {
                    if let directory { try? FileManager.default.removeItem(at: directory) }
                }
                guard let self, self.capture === process else { return }
                self.temporaryDirectory = nil
                self.capture = nil
                self.captureItem.isEnabled = self.textState.id == nil
                if let taskID, let file {
                    guard self.textState.id == taskID else { return }
                    guard process.terminationStatus == 0,
                          let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        self.finishTextCapture(id: taskID, text: nil)
                        return
                    }
                    self.recognizeText(image, id: taskID)
                } else if process.terminationStatus != 0 {
                    self.showError("未能将截图复制到剪贴板，请检查屏幕录制权限后重试。")
                }
            }
        }
        capture = process
        captureItem.isEnabled = false
        // Let the selection overlay disappear before capturing the display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard self.capture === process else { return }
            do { try process.run() }
            catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                self.temporaryDirectory = nil
                self.capture = nil
                self.captureItem.isEnabled = true
                if let taskID { self.finishTextCapture(id: taskID, text: nil) }
                else { self.showError(error.localizedDescription) }
            }
        }
    }

    private func recognizeText(_ image: CGImage, id: UUID) {
        let request = VNRecognizeTextRequest()
        recognitionRequest = request
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let text = try recognizedText(in: image, request: request)
                DispatchQueue.main.async { self.finishTextCapture(id: id, text: text) }
            } catch {
                DispatchQueue.main.async { self.finishTextCapture(id: id, text: nil) }
            }
        }
    }

    private func finishTextCapture(id: UUID, text: String?) {
        guard textState.id == id else { return }
        _ = textState.complete(id: id, text: text, pasteboard: .general)
        recognitionRequest = nil
        unregisterCancelHotKey()
        captureItem.isEnabled = true
    }

    private func cancelTextCapture() {
        guard textState.id != nil else { return }
        textState.id = nil
        recognitionRequest?.cancel()
        recognitionRequest = nil
        if let capture {
            if capture.isRunning { capture.terminate() }
            else {
                self.capture = nil
                if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
                temporaryDirectory = nil
            }
        }
        unregisterCancelHotKey()
        captureItem.isEnabled = capture == nil
    }

    private func unregisterCancelHotKey() {
        if let cancelHotKey { UnregisterEventHotKey(cancelHotKey) }
        cancelHotKey = nil
    }

    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quitApp() {
        cancelTextCapture()
        if let capture, capture.isRunning {
            capture.terminate()
            capture.waitUntilExit()
        }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
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
    precondition(CaptureAction.confirmation(keyCode: 36, modifiers: []) == .image)
    precondition(CaptureAction.confirmation(keyCode: 36, modifiers: .command) == .text)
    precondition(CaptureAction.confirmation(keyCode: 76, modifiers: .command) == .text)
    precondition(CaptureAction.confirmation(keyCode: 53, modifiers: []) == nil)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("keep this", forType: .string)
    var textState = TextCaptureState(id: UUID())
    let cancelledID = textState.id!
    textState.id = nil
    precondition(!textState.complete(id: cancelledID, text: "late result", pasteboard: pasteboard))
    textState.id = UUID()
    precondition(!textState.complete(id: cancelledID, text: "old task", pasteboard: pasteboard))
    precondition(!textState.complete(id: textState.id!, text: " \n", pasteboard: pasteboard))
    textState.id = UUID()
    precondition(!textState.complete(id: textState.id!, text: nil, pasteboard: pasteboard))
    precondition(pasteboard.string(forType: .string) == "keep this")
    textState.id = UUID()
    precondition(textState.complete(id: textState.id!, text: "简体中文\n繁體中文 English", pasteboard: pasteboard))
    precondition(pasteboard.string(forType: .string) == "简体中文\n繁體中文 English")
    precondition(textState.id == nil)
    let context = CGContext(data: nil, width: 800, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 240))
    let blank = context.makeImage()!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let lines = ["Hello Meowshot", "简体中文截图", "繁體中文截圖"]
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 20, y: 175 - index * 70),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    do {
        let text = try recognizedText(in: context.makeImage()!, request: VNRecognizeTextRequest())
        for line in lines {
            precondition(text.replacingOccurrences(of: " ", with: "").contains(line.replacingOccurrences(of: " ", with: "")),
                         "OCR fixture missing \(line): \(text)")
        }
        precondition(text.contains("\n"), "OCR must retain line breaks")
        let empty = try recognizedText(in: blank, request: VNRecognizeTextRequest())
        precondition(empty.isEmpty)
    } catch { fatalError("OCR fixture failed: \(error)") }
    var permission = CapturePermission()
    precondition(permission.action(granted: false) == .request)
    precondition(permission.action(granted: false) == .settings)
    precondition(permission.action(granted: true) == .capture)
    precondition(permission.action(granted: false) == .settings)
    var authorized = CapturePermission()
    precondition(authorized.action(granted: true) == .capture)
    precondition(authorized.action(granted: false) == .request)
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    var selection = RegionSelection()
    selection.begin(at: CGPoint(x: 300, y: 300))
    selection.drag(to: CGPoint(x: 100, y: 100), within: bounds)
    precondition(selection.rect == CGRect(x: 100, y: 100, width: 200, height: 200))
    selection.begin(at: CGPoint(x: 200, y: 200))
    selection.drag(to: CGPoint(x: 1200, y: 900), within: bounds)
    precondition(selection.rect == CGRect(x: 800, y: 600, width: 200, height: 200))
    selection.begin(at: CGPoint(x: 800, y: 600))
    selection.drag(to: CGPoint(x: 700, y: 500), within: bounds)
    precondition(selection.rect == CGRect(x: 700, y: 500, width: 300, height: 300))
    selection.begin(at: CGPoint(x: 850, y: 500))
    selection.drag(to: CGPoint(x: 850, y: 400), within: bounds)
    precondition(selection.rect == CGRect(x: 700, y: 400, width: 300, height: 400))
    let region = selection.captureRect(desktop: CGRect(x: -1000, y: -200, width: 2000, height: 1000), mainScreenTop: 800)
    precondition(region == CGRect(x: -300, y: 200, width: 300, height: 400))
    precondition(captureArguments(rect: region) == ["-c", "-x", "-t", "png", "-R-300,200,300,400"])
    let file = URL(fileURLWithPath: "/tmp/ocr capture.png")
    precondition(captureArguments(rect: region, file: file) == ["-x", "-t", "png", "-R-300,200,300,400", file.path])
    selection.begin(at: CGPoint(x: 50, y: 50))
    precondition(selection.rect.isEmpty)
    selection.drag(to: CGPoint(x: 60, y: 60), within: bounds)
    selection.begin(at: CGPoint(x: 54, y: 55))
    selection.drag(to: CGPoint(x: 80, y: 30), within: bounds)
    precondition(selection.rect == CGRect(x: 60, y: 30, width: 20, height: 30), "Small selections must resize across the opposite edge")
    print("PASS: permission flow, selection, coordinates, capture destinations, OCR actions and clipboard success/failure/cancellation")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
