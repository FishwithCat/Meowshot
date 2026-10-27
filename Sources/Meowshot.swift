import AppKit
import Carbon
import Vision

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

enum AnnotationTool: Int {
    case rectangle, arrow, text
}

let annotationFont = NSFont.systemFont(ofSize: 20, weight: .semibold)

enum Annotation {
    case rectangle(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case text(String, at: CGPoint)

    func draw() {
        let color = NSColor.systemRed
        switch self {
        case let .rectangle(from, to):
            let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                              width: abs(to.x - from.x), height: abs(to.y - from.y))
            guard rect.width >= 1, rect.height >= 1 else { return }
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 3
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case let .arrow(from, to):
            guard hypot(to.x - from.x, to.y - from.y) >= 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: from)
            path.line(to: to)
            let angle = atan2(to.y - from.y, to.x - from.x)
            for offset in [CGFloat.pi - 0.5, CGFloat.pi + 0.5] {
                path.move(to: to)
                path.line(to: CGPoint(x: to.x + cos(angle + offset) * 15,
                                      y: to.y + sin(angle + offset) * 15))
            }
            color.setStroke()
            path.stroke()
        case let .text(text, at):
            (text as NSString).draw(at: at, withAttributes: [.font: annotationFont, .foregroundColor: color])
        }
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

    func croppedImage(from image: CGImage, desktopSize: CGSize) -> CGImage? {
        let scaleX = CGFloat(image.width) / desktopSize.width
        let scaleY = CGFloat(image.height) / desktopSize.height
        let pixels = CGRect(x: rect.minX * scaleX, y: (desktopSize.height - rect.maxY) * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY).integral
        return image.cropping(to: pixels)
    }

    func renderedImage(from image: CGImage, desktopSize: CGSize, annotations: [Annotation]) -> CGImage? {
        guard let crop = croppedImage(from: image, desktopSize: desktopSize), rect.width >= 1, rect.height >= 1,
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: CGFloat(crop.width) / rect.width, y: CGFloat(crop.height) / rect.height)
        NSImage(cgImage: crop, size: rect.size).draw(in: CGRect(origin: .zero, size: rect.size))
        context.translateBy(x: -rect.minX, y: -rect.minY)
        NSBezierPath(rect: rect).addClip()
        for annotation in annotations { annotation.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if firstResponder is NSText { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.contains(.command),
           CaptureAction.confirmation(keyCode: event.keyCode, modifiers: event.modifierFlags) != nil {
            contentView?.keyDown(with: event)
            return true
        }
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift),
           event.keyCode == UInt16(kVK_ANSI_Z),
           let view = contentView as? SelectionView, view.undoAnnotation() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class ToolButton: NSButton {
    var isChosen = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen {
            NSColor.white.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

final class ToolbarView: NSView {
    var onSelect: ((AnnotationTool?) -> Void)?
    var onClear: (() -> Void)?
    var canClear = false {
        didSet { clearButton?.alphaValue = canClear ? 1 : 0.45 }
    }
    private(set) var chosenTool: AnnotationTool? {
        didSet {
            for (index, button) in buttons.enumerated() { button.isChosen = tools[index] == chosenTool }
        }
    }
    private let tools: [AnnotationTool?] = [nil, .rectangle, .arrow, .text]
    private var buttons: [ToolButton] = []
    private var clearButton: ToolButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 276, height: 34))
        let titles = ["鼠标", "框选", "箭头", "文字"]
        let tips = ["调整截图范围（拖动内部移动，拖动边缘缩放）", "绘制矩形框", "绘制箭头", "输入文字"]
        for index in titles.indices {
            let button = ToolButton(frame: NSRect(x: 4 + index * 52, y: 3, width: 52, height: 28))
            button.isBordered = false
            button.focusRingType = .none
            button.setButtonType(.momentaryChange)
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
            button.attributedTitle = NSAttributedString(string: titles[index], attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ])
            button.toolTip = tips[index]
            button.isChosen = tools[index] == chosenTool
            addSubview(button)
            buttons.append(button)
        }
        let clear = ToolButton(frame: NSRect(x: 220, y: 3, width: 52, height: 28))
        clear.isBordered = false
        clear.focusRingType = .none
        clear.setButtonType(.momentaryChange)
        clear.target = self
        clear.action = #selector(clearAll(_:))
        clear.attributedTitle = NSAttributedString(string: "清除", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        clear.toolTip = "清除全部标注（⌘Z 可撤销）"
        clear.setAccessibilityLabel("清除全部标注")
        // Keep it enabled: a disabled button lets the click fall through to SelectionView and reset the selection.
        clear.isEnabled = true
        clear.alphaValue = 0.45
        addSubview(clear)
        clearButton = clear
        setAccessibilityLabel("标注工具")
        setAccessibilityHelp("鼠标模式可移动和缩放选区，标注工具用于绘制，清除按钮清空全部标注。")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(white: 0.10, alpha: 1).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.20).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func choose(_ sender: ToolButton) {
        chosenTool = tools[sender.tag]
        onSelect?(chosenTool)
    }

    @objc private func clearAll(_ sender: ToolButton) {
        onClear?()
    }
}

final class SelectionView: NSView, NSTextFieldDelegate {
    var snapshot: NSImage?
    var selection = RegionSelection()
    var annotations: [Annotation] = [] {
        didSet { toolbar.canClear = !annotations.isEmpty }
    }
    var finish: ((CaptureAction?) -> Void)?
    private(set) var tool: AnnotationTool?
    private var pendingShape: (kind: AnnotationTool, start: CGPoint, end: CGPoint)?
    private var adjustingSelection = false
    private var textField: NSTextField?
    private var annotationHistory: [[Annotation]] = []
    private lazy var toolbar = ToolbarView(frame: .zero)

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolbar.onSelect = { [weak self] tool in self?.select(tool) }
        toolbar.onClear = { [weak self] in self?.clearAnnotations() }
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        snapshot?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection.rect)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        shade.fill()
        if !selection.rect.isEmpty {
            NSColor.white.setStroke()
            NSBezierPath(rect: selection.rect).stroke()
            if tool == nil {
                NSColor.white.setFill()
                for x in [selection.rect.minX, selection.rect.midX, selection.rect.maxX] {
                    for y in [selection.rect.minY, selection.rect.midY, selection.rect.maxY] {
                        if x == selection.rect.midX && y == selection.rect.midY { continue }
                        NSBezierPath(rect: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
                    }
                }
            }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection.rect).addClip()
            for annotation in annotations { annotation.draw() }
            if let pendingShape {
                switch pendingShape.kind {
                case .rectangle:
                    Annotation.rectangle(from: pendingShape.start, to: pendingShape.end).draw()
                case .arrow:
                    Annotation.arrow(from: pendingShape.start, to: pendingShape.end).draw()
                case .text:
                    break
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commitText()
        selection.begin(at: point)
        pendingShape = nil
        if selection.rect.isEmpty {
            if !annotations.isEmpty { recordAnnotations() }
            annotations.removeAll()
            adjustingSelection = true
        } else if tool == nil {
            adjustingSelection = true
        } else if let tool, selection.rect.contains(point) {
            adjustingSelection = false
            switch tool {
            case .rectangle, .arrow:
                pendingShape = (tool, point, point)
            case .text:
                beginText(at: point)
            }
        } else {
            adjustingSelection = true
        }
        layoutToolbar()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if adjustingSelection {
            selection.drag(to: point, within: bounds)
            layoutToolbar()
        } else if var shape = pendingShape {
            shape.end = point
            pendingShape = shape
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let shape = pendingShape {
            switch shape.kind {
            case .rectangle:
                if abs(shape.end.x - shape.start.x) >= 4, abs(shape.end.y - shape.start.y) >= 4 {
                    recordAnnotations()
                    annotations.append(.rectangle(from: shape.start, to: shape.end))
                }
            case .arrow:
                if hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y) >= 4 {
                    recordAnnotations()
                    annotations.append(.arrow(from: shape.start, to: shape.end))
                }
            case .text:
                break
            }
            pendingShape = nil
            needsDisplay = true
        }
        adjustingSelection = false
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        if textField == nil { window?.makeFirstResponder(self) }
        layoutToolbar()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish?(nil) }
        else if let action = CaptureAction.confirmation(keyCode: event.keyCode, modifiers: event.modifierFlags),
                selection.rect.width >= 1, selection.rect.height >= 1 { finish?(action) }
    }

    private func select(_ newTool: AnnotationTool?) {
        commitText()
        tool = newTool
        pendingShape = nil
        adjustingSelection = false
        window?.makeFirstResponder(self)
        layoutToolbar()
        needsDisplay = true
    }

    @discardableResult
    func undoAnnotation() -> Bool {
        guard let previous = annotationHistory.popLast() else { return false }
        annotations = previous
        needsDisplay = true
        window?.makeFirstResponder(self)
        return true
    }

    func clearAnnotations() {
        commitText()
        window?.makeFirstResponder(self)
        guard !annotations.isEmpty else { return }
        recordAnnotations()
        annotations.removeAll()
        needsDisplay = true
    }

    private func recordAnnotations() {
        annotationHistory.append(annotations)
        if annotationHistory.count > 20 { annotationHistory.removeFirst() }
    }

    private func layoutToolbar() {
        guard !selection.rect.isEmpty else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        let size = toolbar.frame.size
        var x = selection.rect.midX - size.width / 2
        var y = selection.rect.minY - size.height - 10
        if y < bounds.minY + 10 { y = selection.rect.maxY + 10 }
        if y + size.height > bounds.maxY - 10 {
            y = min(max(bounds.minY + 10, selection.rect.minY + 10), bounds.maxY - size.height - 10)
        }
        x = min(max(bounds.minX + 10, x), bounds.maxX - size.width - 10)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        toolbar.frame.origin = CGPoint(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale)
    }

    private func beginText(at point: CGPoint) {
        let width = min(240, selection.rect.width)
        let field = NSTextField(frame: NSRect(x: min(point.x, selection.rect.maxX - width),
                                             y: min(point.y, selection.rect.maxY - 30),
                                             width: width, height: 30))
        field.font = annotationFont
        field.textColor = .systemRed
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = field.frame.origin
        field.removeFromSuperview()
        if !text.isEmpty {
            recordAnnotations()
            annotations.append(.text(text, at: origin))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func discardText() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: annotationFont]).width + 16
        field.frame.size.width = min(max(80, width), selection.rect.maxX - field.frame.minX)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            discardText()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        return false
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
    private var captureItem: NSMenuItem!
    private var selectionWindow: NSWindow?
    private var permission = CapturePermission()
    private var textState = TextCaptureState()
    private var recognitionRequest: VNRecognizeTextRequest?
    private var cancelHotKey: EventHotKeyRef?
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
        guard selectionWindow == nil, textState.id == nil else { return }
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
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let captureBounds = CGRect(x: desktop.minX, y: mainScreen.frame.maxY - desktop.maxY,
                                   width: desktop.width, height: desktop.height)
        guard let snapshot = CGWindowListCreateImage(captureBounds, .optionOnScreenOnly,
                                                     kCGNullWindowID, .bestResolution) else {
            showError("未能截取屏幕，请检查屏幕录制权限后重试。")
            return
        }
        previousApplication = NSWorkspace.shared.frontmostApplication
        let window = SelectionWindow(contentRect: desktop, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: CGRect(origin: .zero, size: desktop.size))
        view.snapshot = NSImage(cgImage: snapshot, size: desktop.size)
        view.setAccessibilityLabel("截图选区")
        view.setAccessibilityHelp("拖动选区内部移动，拖动边缘调整大小。工具条可切回鼠标调整选区，或绘制矩形框、箭头和文字；清除按钮删除全部标注，Command Z 撤销上一笔。Return 复制图片，Command Return 复制文字，Escape 取消。")
        view.finish = { [weak self, weak view] action in
            guard let self, let view else { return }
            self.selectionWindow?.close()
            self.selectionWindow = nil
            self.previousApplication?.activate(options: .activateIgnoringOtherApps)
            self.previousApplication = nil
            self.captureItem.isEnabled = true
            if let action {
                let image = action == .image
                    ? view.selection.renderedImage(from: snapshot, desktopSize: desktop.size, annotations: view.annotations)
                    : view.selection.croppedImage(from: snapshot, desktopSize: desktop.size)
                if let image { self.takeScreenshot(image: image, action: action) }
            }
        }
        window.contentView = view
        selectionWindow = window
        captureItem.isEnabled = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func takeScreenshot(image: CGImage, action: CaptureAction) {
        if action == .image {
            let item = NSPasteboardItem()
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  item.setData(data, forType: .png) else { return }
            NSPasteboard.general.clearContents()
            if !NSPasteboard.general.writeObjects([item]) {
                showError("未能将截图复制到剪贴板，请重试。")
            }
            return
        }
        let id = UUID()
        textState.id = id
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x4D454F57, id: 2),
                                         GetApplicationEventTarget(), 0, &cancelHotKey)
        guard result == noErr else {
            finishTextCapture(id: id, text: nil)
            return
        }
        captureItem.isEnabled = false
        recognizeText(image, id: id)
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
        unregisterCancelHotKey()
        captureItem.isEnabled = true
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
    let cropContext = CGContext(data: nil, width: 2000, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cropContext.setFillColor(CGColor(gray: 1, alpha: 1))
    cropContext.fill(CGRect(x: 1400, y: 800, width: 600, height: 800))
    let frozen = cropContext.makeImage()!
    // Mutating the source after capture must not change the selected frame.
    cropContext.setFillColor(CGColor(gray: 0, alpha: 1))
    cropContext.fill(CGRect(x: 0, y: 0, width: 2000, height: 1600))
    let crop = selection.croppedImage(from: frozen, desktopSize: bounds.size)!
    precondition(crop.width == 600 && crop.height == 800, "Crop must preserve Retina pixels")
    let pixels = crop.dataProvider!.data! as Data
    precondition(pixels[0] == 255 && pixels[1] == 255 && pixels[2] == 255,
                 "Crop must use the frozen frame and convert bottom-left selection coordinates")
    let preview = SelectionView(frame: bounds)
    preview.snapshot = NSImage(cgImage: frozen, size: bounds.size)
    preview.selection = selection
    let keptSelection = preview.selection.rect
    preview.annotations = [.arrow(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 55, y: 30))]
    preview.clearAnnotations()
    precondition(preview.annotations.isEmpty, "Clear must remove all annotations")
    precondition(preview.selection.rect == keptSelection, "Clear must keep the selection")
    precondition(preview.undoAnnotation(), "Undo must restore cleared annotations")
    precondition(preview.annotations.count == 1)
    precondition(!preview.undoAnnotation(), "Undo must stop at the first recorded state")
    preview.annotations = []
    preview.clearAnnotations()
    precondition(!preview.undoAnnotation(), "Clearing nothing must not add undo history")
    let toolbar = ToolbarView(frame: .zero)
    let clearButton = toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == "清除" }
    precondition(clearButton?.isEnabled == true,
                 "The clear button must stay enabled so a click cannot fall through to the selection")
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cropContext, flipped: false)
    cropContext.scaleBy(x: 2, y: 2)
    preview.draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    let rendered = NSBitmapImageRep(cgImage: cropContext.makeImage()!)
    precondition(rendered.colorAt(x: 1700, y: 400)!.usingColorSpace(.deviceRGB)!.redComponent > 0.99,
                 "The selection interior must display the frozen image instead of the live desktop")
    selection.begin(at: CGPoint(x: 50, y: 50))
    precondition(selection.rect.isEmpty)
    selection.drag(to: CGPoint(x: 60, y: 60), within: bounds)
    selection.begin(at: CGPoint(x: 54, y: 55))
    selection.drag(to: CGPoint(x: 80, y: 30), within: bounds)
    precondition(selection.rect == CGRect(x: 60, y: 30, width: 20, height: 30), "Small selections must resize across the opposite edge")

    var annotatedSelection = RegionSelection()
    annotatedSelection.rect = CGRect(x: 10, y: 10, width: 50, height: 50)
    let annotationContext = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    annotationContext.setFillColor(CGColor(gray: 1, alpha: 1))
    annotationContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    annotationContext.setFillColor(CGColor(gray: 0, alpha: 1))
    annotationContext.fill(CGRect(x: 0, y: 40, width: 200, height: 20))
    let annotationSource = annotationContext.makeImage()!
    func redPixelCount(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.6, color.greenComponent < 0.5 { count += 1 }
            }
        }
        return count
    }
    let desktopSize = CGSize(width: 100, height: 100)
    let plainImage = annotatedSelection.renderedImage(from: annotationSource, desktopSize: desktopSize, annotations: [])!
    precondition(redPixelCount(plainImage) == 0, "Empty annotations must not alter the copied image")
    let markedImage = annotatedSelection.renderedImage(
        from: annotationSource, desktopSize: desktopSize,
        annotations: [.arrow(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 55, y: 30)),
                      .text("Hi", at: CGPoint(x: 15, y: 40))])!
    precondition(redPixelCount(markedImage) > 100, "Arrows and text must render into the copied image")
    let markedPixels = NSBitmapImageRep(cgImage: markedImage)
    // colorAt uses top-left pixel coordinates: the arrow sits 40px above the selection bottom.
    let arrowPixel = markedPixels.colorAt(x: 40, y: 60)!.usingColorSpace(.deviceRGB)!
    precondition(arrowPixel.redComponent > 0.6 && arrowPixel.greenComponent < 0.5,
                 "The arrow must keep selection-relative coordinates")
    let topPixel = markedPixels.colorAt(x: 5, y: 30)!.usingColorSpace(.deviceRGB)!
    let bandPixel = markedPixels.colorAt(x: 5, y: 70)!.usingColorSpace(.deviceRGB)!
    precondition(topPixel.redComponent > 0.99 && bandPixel.redComponent < 0.01,
                 "The copied image must keep its orientation")
    let rectangleImage = annotatedSelection.renderedImage(
        from: annotationSource, desktopSize: desktopSize,
        annotations: [.rectangle(from: CGPoint(x: 15, y: 20), to: CGPoint(x: 45, y: 40))])!
    let rectanglePixels = NSBitmapImageRep(cgImage: rectangleImage)
    precondition(rectanglePixels.colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!.redComponent > 0.6,
                 "The rectangle tool must draw an outline")
    precondition(rectanglePixels.colorAt(x: 40, y: 55)!.usingColorSpace(.deviceRGB)!.redComponent > 0.99,
                 "The rectangle interior must stay transparent")
    let outsideImage = annotatedSelection.renderedImage(
        from: annotationSource, desktopSize: desktopSize,
        annotations: [.arrow(from: CGPoint(x: 70, y: 70), to: CGPoint(x: 90, y: 90))])!
    precondition(redPixelCount(outsideImage) == 0, "Annotations outside the selection must be clipped")
    print("PASS: permission flow, selection, frozen Retina crop, rectangle/arrow/text annotations, annotation undo/clear, OCR actions and clipboard success/failure/cancellation")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
