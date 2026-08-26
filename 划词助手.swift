// 划词助手.swift — macOS 剪贴板翻译助手（Cmd+C 触发）
// 编译: swiftc -O 划词助手.swift -o 划词助手
// 用法: ./划词助手 [--check] [--debug]
//
// 功能:
//   1. 监听剪贴板：选中文字后按 Cmd+C，弹出翻译浮动窗（无需辅助功能权限）
//   2. 若已获得辅助功能权限，会尽力读取上下文（3-5句）提供语境翻译
//   3. 菜单栏图标「译」：设置（大小/字号/透明度/时长）、暂停、退出
//   4. 弹窗带「复制译文」按钮

import Cocoa
import ApplicationServices

let SERVER_URL = URL(string: "http://127.0.0.1:6688/api/context-translate")!

// 旧 SDK 未导出的辅助功能常量（字符串形式声明）
let kAXBoundsForRangeAttribute = "AXBoundsForRange" as CFString
let kAXDocumentTextAttribute = "AXDocumentText" as CFString

// MARK: - 颜色工具
func colorToHex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "%02X%02X%02X", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
}
func hexToColor(_ hex: String, fallback: UInt32) -> NSColor {
    var h = hex.trimmingCharacters(in: .whitespaces).uppercased()
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return rgb(fallback) }
    return rgb(v)
}
func rgb(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
func contrastingTextColor(_ c: NSColor) -> NSColor {
    let s = c.usingColorSpace(.sRGB) ?? c
    let lum = 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent
    return lum > 0.6 ? NSColor.black : NSColor.white
}

// MARK: - 设置（UserDefaults 持久化）
enum Settings {
    static let widthKey = "popupWidth"
    static let origFontKey = "popupOrigFontSize"
    static let transFontKey = "popupTransFontSize"
    static let opacityKey = "popupOpacity"
    static let bgColorKey = "popupBgColor"
    static let copyColorKey = "popupCopyColor"
    static let closeColorKey = "popupCloseColor"
    static let origColorKey = "popupOrigColor"
    static let transColorKey = "popupTransColor"
    static let radiusKey = "popupRadius"

    static var width: CGFloat { CGFloat(UserDefaults.standard.double(forKey: widthKey) != 0 ? UserDefaults.standard.double(forKey: widthKey) : 380) }
    static var origFontSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: origFontKey) != 0 ? UserDefaults.standard.double(forKey: origFontKey) : 14) }
    static var transFontSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: transFontKey) != 0 ? UserDefaults.standard.double(forKey: transFontKey) : 16) }
    static var opacity: CGFloat { UserDefaults.standard.double(forKey: opacityKey) != 0 ? CGFloat(UserDefaults.standard.double(forKey: opacityKey)) : 0.65 }
    // 默认苹果配色（与网页一致）：米黄奶油底 + 苹果红
    static var bgColor: NSColor { hexToColor(UserDefaults.standard.string(forKey: bgColorKey) ?? "", fallback: 0x000000) }
    static var copyColor: NSColor { hexToColor(UserDefaults.standard.string(forKey: copyColorKey) ?? "", fallback: 0xFBF6EC) }
    static var closeColor: NSColor { hexToColor(UserDefaults.standard.string(forKey: closeColorKey) ?? "", fallback: 0xFFFFFF) }
    static var origColor: NSColor { hexToColor(UserDefaults.standard.string(forKey: origColorKey) ?? "", fallback: 0xFF3B30) }
    static var transColor: NSColor { hexToColor(UserDefaults.standard.string(forKey: transColorKey) ?? "", fallback: 0xFBF6EC) }
    static var radius: CGFloat { CGFloat(UserDefaults.standard.double(forKey: radiusKey) != 0 ? UserDefaults.standard.double(forKey: radiusKey) : 20) }

    static func save(width: CGFloat, radius: CGFloat, origFontSize: CGFloat, transFontSize: CGFloat, opacity: CGFloat,
                     bgColor: NSColor, copyColor: NSColor, closeColor: NSColor,
                     origColor: NSColor, transColor: NSColor) {
        UserDefaults.standard.set(Double(width), forKey: widthKey)
        UserDefaults.standard.set(Double(radius), forKey: radiusKey)
        UserDefaults.standard.set(Double(origFontSize), forKey: origFontKey)
        UserDefaults.standard.set(Double(transFontSize), forKey: transFontKey)
        UserDefaults.standard.set(Double(opacity), forKey: opacityKey)
        UserDefaults.standard.set(colorToHex(bgColor), forKey: bgColorKey)
        UserDefaults.standard.set(colorToHex(copyColor), forKey: copyColorKey)
        UserDefaults.standard.set(colorToHex(closeColor), forKey: closeColorKey)
        UserDefaults.standard.set(colorToHex(origColor), forKey: origColorKey)
        UserDefaults.standard.set(colorToHex(transColor), forKey: transColorKey)
    }
    static func reset() {
        UserDefaults.standard.removeObject(forKey: widthKey)
        UserDefaults.standard.removeObject(forKey: radiusKey)
        UserDefaults.standard.removeObject(forKey: origFontKey)
        UserDefaults.standard.removeObject(forKey: transFontKey)
        UserDefaults.standard.removeObject(forKey: opacityKey)
        UserDefaults.standard.removeObject(forKey: bgColorKey)
        UserDefaults.standard.removeObject(forKey: copyColorKey)
        UserDefaults.standard.removeObject(forKey: closeColorKey)
        UserDefaults.standard.removeObject(forKey: origColorKey)
        UserDefaults.standard.removeObject(forKey: transColorKey)
    }
}

// MARK: - 调试日志
var debugMode = false
func debugLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    do {
        if FileManager.default.fileExists(atPath: "/tmp/xuanci-debug.log") {
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/xuanci-debug.log"))
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try fh.close()
        } else {
            try line.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/xuanci-debug.log"))
        }
    } catch {}
    if debugMode { print(msg, terminator: "") }
}

// MARK: - 辅助功能（尽力读取上下文用，非必需）
func axCopy(_ el: AXUIElement, _ attr: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, attr, &value)
    return err == .success ? value : nil
}
func frontmostAppElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return AXUIElementCreateApplication(app.processIdentifier)
}
func focusedElement() -> AXUIElement? {
    guard let appEl = frontmostAppElement() else { return nil }
    if let focused = axCopy(appEl, kAXFocusedUIElementAttribute as CFString),
       CFGetTypeID(focused) == AXUIElementGetTypeID() {
        return focused as! AXUIElement
    }
    guard let focusedApp = axCopy(appEl, kAXFocusedApplicationAttribute as CFString),
          CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else { return nil }
    let focusedAppEl = focusedApp as! AXUIElement
    guard let focused = axCopy(focusedAppEl, kAXFocusedUIElementAttribute as CFString),
          CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    return focused as! AXUIElement
}
func stringAttr(_ el: AXUIElement, _ attr: CFString) -> String? {
    guard let v = axCopy(el, attr), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    return v as? String
}

// 尽力读取上下文：定位剪贴板文本在聚焦文档中的位置，返回前后 ~1600 字符
func bestEffortContext(selection: String) -> String {
    guard AXIsProcessTrusted() else { return "" }
    guard let el = focusedElement() else { return "" }
    var value = stringAttr(el, kAXValueAttribute as CFString)
    if value == nil || value!.isEmpty { value = stringAttr(el, kAXDocumentTextAttribute as CFString) }
    guard let full = value, !full.isEmpty else { return "" }
    let normFull = full.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    let normSel = selection.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    // 统一使用 NSString 的 UTF-16 单位定位/截取，避免与 Swift Character 计数混用产生乱码
    let nsFull = normFull as NSString
    let found = nsFull.range(of: normSel)
    if found.location == NSNotFound { return "" }
    let lo = max(0, found.location - 1600)
    let hi = min(nsFull.length, found.location + found.length + 1600)
    return nsFull.substring(with: NSRange(location: lo, length: hi - lo))
}

// MARK: - HTTP 客户端
func requestTranslation(selection: String, context: String, bounds: CGRect?) -> [String: Any]? {
    var req = URLRequest(url: SERVER_URL)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["selection": selection, "context": context]
    if let b = bounds {
        body["bounds"] = ["x": b.origin.x, "y": b.origin.y, "w": b.width, "h": b.height]
    }
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let sem = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    let task = URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = obj
        }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 30)
    return result
}

// MARK: - 浮动窗（带复制按钮，应用设置；可拖拽移动）
// 文本区允许拖拽窗口（mouseDownCanMoveWindow = true），按钮仍可点击
final class DragTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class PopupPanel: NSPanel {
    let scroll = NSScrollView()
    let textView = DragTextView()
    let copyBtn = NSButton()
    let settingsBtn = NSButton()
    let closeBtn = NSButton()
    var copyText = ""

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear   // 窗口本身透明，背景画在内容层上（圆角才可见）
        isMovableByWindowBackground = true   // 按住弹窗任意空白/文本处可拖动
        level = .floating
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = Settings.radius
        contentView?.layer?.masksToBounds = true
        contentView?.layer?.backgroundColor = Settings.bgColor.withAlphaComponent(Settings.opacity).cgColor

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        copyBtn.title = "复制译文"
        copyBtn.font = NSFont.systemFont(ofSize: 11)
        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyTapped)
        settingsBtn.title = "设置"
        settingsBtn.font = NSFont.systemFont(ofSize: 11)
        settingsBtn.bezelStyle = .rounded
        settingsBtn.target = self
        settingsBtn.action = #selector(settingsTapped)
        closeBtn.title = "✕"
        closeBtn.font = NSFont.systemFont(ofSize: 11)
        closeBtn.bezelStyle = .rounded
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        styleButtons()

        let bar = NSStackView(views: [copyBtn, settingsBtn, closeBtn])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        bar.alignment = .centerY

        let wrap = NSView(frame: contentView!.bounds)
        wrap.autoresizingMask = [.width, .height]
        contentView?.addSubview(wrap)
        wrap.addSubview(scroll)
        wrap.addSubview(bar)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: wrap.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func copyTapped() {
        if !copyText.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(copyText, forType: .string)
            // 同步剪贴板监听状态：这是「复制译文」写入的，不是用户新划词 → 不触发新弹窗
            monLastChange = pb.changeCount
            monLastHandled = copyText
            monLastTime = Date().timeIntervalSince1970
        }
        copyBtn.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyBtn.title = "复制译文"
        }
    }
    @objc func closeTapped() { orderOut(nil) }
    @objc func settingsTapped() {
        guard settingsPanel != nil else { return }
        settingsPanel.refreshLabels()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel.makeKeyAndOrderFront(nil)
        settingsPanel.orderFrontRegardless()
        settingsPanel.center()
        DispatchQueue.main.async { settingsPanel.resizeWindow() }
    }

    func size(for attr: NSAttributedString, maxWidth: CGFloat) -> NSSize {
        let container = NSTextContainer(containerSize: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        let ts = NSTextStorage(attributedString: attr)
        ts.addLayoutManager(lm)
        lm.addTextContainer(container)
        _ = lm.glyphRange(for: container)
        return lm.usedRect(for: container).size
    }

    func show(attr: NSAttributedString, copy: String, near point: NSPoint) {
        copyText = copy
        textView.textStorage?.setAttributedString(attr)
        backgroundColor = .clear
        contentView?.layer?.backgroundColor = Settings.bgColor.withAlphaComponent(Settings.opacity).cgColor
        contentView?.layer?.cornerRadius = Settings.radius
        styleButtons()

        let w = Settings.width                        // 窗口宽度 = 设置值（修复滑杆无效果）
        let pad: CGFloat = 28
        let textW = w - pad
        let measured = size(for: attr, maxWidth: textW)
        let textH = min(360, max(40, measured.height + pad))
        let h = textH + 34
        textView.frame = NSRect(x: 0, y: 0, width: textW, height: textH)

        let screens = NSScreen.screens
        let screen = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? screens.first
        guard let scr = screen else { return }
        var x = point.x - 12
        var y = point.y - h - 10
        if y < scr.visibleFrame.minY + 4 { y = point.y + 14 }
        if x + w > scr.visibleFrame.maxX { x = scr.visibleFrame.maxX - w - 8 }
        if x < scr.visibleFrame.minX { x = scr.visibleFrame.minX + 8 }

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        orderFrontRegardless()
        // 不自动隐藏：由「✕」关闭键手动关闭
    }

    func styleButtons() {
        func apply(_ btn: NSButton, _ color: NSColor) {
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 6
            btn.layer?.backgroundColor = color.cgColor
            let tc = contrastingTextColor(color)
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            btn.attributedTitle = NSAttributedString(string: btn.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: tc,
            ])
            btn.contentTintColor = tc
        }
        apply(copyBtn, Settings.copyColor)
        apply(settingsBtn, Settings.copyColor)
        apply(closeBtn, Settings.closeColor)
    }
}

// MARK: - 设置窗口
final class SettingsPanel: NSPanel {
    let widthSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    let radiusSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    let origFontSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    let transFontSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    let opacitySlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    let origColorWell = NSColorWell()
    let transColorWell = NSColorWell()
    let bgWell = NSColorWell()
    let copyWell = NSColorWell()
    let closeWell = NSColorWell()
    let widthLabel = NSTextField(labelWithString: "")
    let radiusLabel = NSTextField(labelWithString: "")
    let origFontLabel = NSTextField(labelWithString: "")
    let transFontLabel = NSTextField(labelWithString: "")
    let opacityLabel = NSTextField(labelWithString: "")
    var sections: [(header: NSButton, detail: NSStackView, key: String)] = []
    let root = NSStackView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                   styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        title = "miaomiao翻译器 · 设置"
        // 层级必须高于翻译弹窗（弹窗不自动消失，同级会挡住设置）
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        for (sl, lo, hi, def) in [
            (widthSlider, 260.0, 560.0, Double(Settings.width)),
            (radiusSlider, 0.0, 28.0, Double(Settings.radius)),
            (origFontSlider, 10.0, 24.0, Double(Settings.origFontSize)),
            (transFontSlider, 10.0, 24.0, Double(Settings.transFontSize)),
            (opacitySlider, 0.3, 1.0, Double(Settings.opacity)),
        ] {
            sl.minValue = lo
            sl.maxValue = hi
            sl.doubleValue = def
            sl.target = self
            sl.action = #selector(changed)
            sl.isContinuous = true
            sl.isEnabled = true
            sl.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        }
        for w in [origColorWell, transColorWell, bgWell, copyWell, closeWell] {
            w.target = self; w.action = #selector(changed)
            w.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        origColorWell.color = Settings.origColor
        transColorWell.color = Settings.transColor
        bgWell.color = Settings.bgColor
        copyWell.color = Settings.copyColor
        closeWell.color = Settings.closeColor

        func sliderRow(_ t: String, _ slider: NSSlider, _ label: NSTextField) -> NSStackView {
            let tt = NSTextField(labelWithString: t)
            tt.font = NSFont.systemFont(ofSize: 12)
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 40).isActive = true
            let row = NSStackView(views: [tt, slider, label])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        func colorRow(_ t: String, _ well: NSColorWell) -> NSStackView {
            let tt = NSTextField(labelWithString: t)
            tt.font = NSFont.systemFont(ofSize: 12)
            let row = NSStackView(views: [tt, well])
            row.orientation = .horizontal
            row.spacing = 8
            return row
        }
        func makeSection(_ title: String, _ rows: [NSView], key: String) -> (NSButton, NSStackView, String) {
            let header = NSButton(title: title, target: self, action: #selector(toggleSection))
            header.isBordered = false
            header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            header.alignment = .left
            header.imagePosition = .imageLeading
            let detail = NSStackView(views: rows)
            detail.orientation = .vertical
            detail.spacing = 8
            detail.edgeInsets = NSEdgeInsets(top: 2, left: 18, bottom: 0, right: 0)
            // 默认展开；用户手动折叠后记住状态
            let expanded = UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
            detail.isHidden = !expanded
            setArrow(header, expanded: expanded)
            return (header, detail, key)
        }
        sections = [
            makeSection("1. 弹窗形式", [
                sliderRow("弹窗宽度", widthSlider, widthLabel),
                sliderRow("圆角弧度", radiusSlider, radiusLabel),
            ], key: "secShape"),
            makeSection("2. 字号", [
                sliderRow("划词字号", origFontSlider, origFontLabel),
                sliderRow("翻译字号", transFontSlider, transFontLabel),
            ], key: "secFont"),
            makeSection("3. 字体颜色", [
                colorRow("划词字体", origColorWell),
                colorRow("翻译字体", transColorWell),
            ], key: "secColor"),
            makeSection("4. 背景", [
                colorRow("背景颜色", bgWell),
                sliderRow("背景透明度", opacitySlider, opacityLabel),
            ], key: "secBg"),
            makeSection("5. 其它", [
                colorRow("复制键", copyWell),
                colorRow("关闭键", closeWell),
            ], key: "secOther"),
        ]

        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetTapped))
        resetBtn.bezelStyle = .rounded

        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for sec in sections {
            let wrap = NSStackView(views: [sec.header, sec.detail])
            wrap.orientation = .vertical
            wrap.spacing = 4
            root.addArrangedSubview(wrap)
        }
        root.addArrangedSubview(resetBtn)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
        ])
        setContentSize(NSSize(width: 420, height: 480))
        contentView?.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError() }

    // accessory 应用（无 Dock 图标）的窗口默认不能成为 key → 控件收不到鼠标事件。
    // 强制可成为 key，滑杆/取色器才能正常交互。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setArrow(_ b: NSButton, expanded: Bool) {
        b.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }

    @objc func toggleSection(_ sender: NSButton) {
        guard let i = sections.firstIndex(where: { $0.header === sender }) else { return }
        let sec = sections[i]
        sec.detail.isHidden.toggle()
        UserDefaults.standard.set(!sec.detail.isHidden, forKey: sec.key)
        setArrow(sender, expanded: !sec.detail.isHidden)
        resizeWindow()
    }

    func resizeWindow() {
        contentView?.layoutSubtreeIfNeeded()
        let h = min(720, max(160, root.fittingSize.height + 40))
        setContentSize(NSSize(width: 420, height: h))
        layoutIfNeeded()
    }

    @objc func changed() {
        refreshLabels()
        Settings.save(width: CGFloat(widthSlider.doubleValue), radius: CGFloat(radiusSlider.doubleValue),
                      origFontSize: CGFloat(origFontSlider.doubleValue), transFontSize: CGFloat(transFontSlider.doubleValue),
                      opacity: CGFloat(opacitySlider.doubleValue),
                      bgColor: bgWell.color, copyColor: copyWell.color, closeColor: closeWell.color,
                      origColor: origColorWell.color, transColor: transColorWell.color)
        applyToPopup()
    }
    @objc func resetTapped() {
        Settings.reset()
        widthSlider.doubleValue = 380; radiusSlider.doubleValue = 20
        origFontSlider.doubleValue = 14; transFontSlider.doubleValue = 16
        opacitySlider.doubleValue = 0.65
        origColorWell.color = Settings.origColor; transColorWell.color = Settings.transColor
        bgWell.color = Settings.bgColor; copyWell.color = Settings.copyColor; closeWell.color = Settings.closeColor
        refreshLabels()
        applyToPopup()
    }
    func refreshLabels() {
        widthLabel.stringValue = "\(Int(widthSlider.doubleValue))"
        radiusLabel.stringValue = "\(Int(radiusSlider.doubleValue))"
        origFontLabel.stringValue = "\(Int(origFontSlider.doubleValue))pt"
        transFontLabel.stringValue = "\(Int(transFontSlider.doubleValue))pt"
        opacityLabel.stringValue = String(format: "%.0f%%", opacitySlider.doubleValue * 100)
    }
    func applyToPopup() {
        popupPanel.backgroundColor = .clear
        popupPanel.contentView?.layer?.backgroundColor = Settings.bgColor.withAlphaComponent(Settings.opacity).cgColor
        popupPanel.contentView?.layer?.cornerRadius = Settings.radius
        popupPanel.styleButtons()
    }
}

// MARK: - 渲染
func attrColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func buildAttributed(_ resp: [String: Any]) -> (attr: NSAttributedString, copy: String) {
    let out = NSMutableAttributedString()
    let ofs = Settings.origFontSize
    let tfs = Settings.transFontSize
    let title = NSFont.systemFont(ofSize: ofs, weight: .bold)
    let body = NSFont.systemFont(ofSize: tfs)
    let small = NSFont.systemFont(ofSize: max(10, tfs - 2))
    let white = Settings.origColor
    let gray = attrColor(0x8A8272)
    let accent = Settings.transColor
    let orange = attrColor(0xB2501E)

    func add(_ s: String, font: NSFont, color: NSColor) {
        out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
    }

    if let err = resp["error"] as? String {
        add("⚠️ " + err, font: body, color: orange)
        return (out, err)
    }

    let completed = resp["completed"] as? String ?? ""
    let kind = resp["kind"] as? String ?? "word"
    let changed = resp["changed"] as? Bool ?? false
    var copyText = completed
    // 大段文字：标题只显示开头，避免弹窗被原文塞满
    let displayHead = completed.count > 80 ? String(completed.prefix(80)) + "…" : completed

    add(displayHead, font: title, color: white)
    if changed {
        add("  (已补齐: " + (resp["original"] as? String ?? "") + " → " + completed + ")", font: small, color: gray)
    }
    out.append(NSAttributedString(string: "\n", attributes: [:]))

    if kind == "sentence" {
        if let t = resp["translation"] as? String, !t.isEmpty {
            copyText = t
            add(t, font: body, color: accent)
            out.append(NSAttributedString(string: "\n", attributes: [:]))
        }
    } else {
        if let t = resp["translation"] as? String, !t.isEmpty {
            copyText = t
            add(t, font: body, color: accent)
            out.append(NSAttributedString(string: "\n", attributes: [:]))
        }
        if let b = resp["bestSense"] as? [String: Any], let sense = b["sense"] as? String {
            copyText = sense
            add("● " + sense, font: body, color: accent)
            out.append(NSAttributedString(string: "\n", attributes: [:]))
        }
        if let senses = resp["dictSenses"] as? [String], !senses.isEmpty, resp["bestSense"] == nil {
            let preview = senses.prefix(3).joined(separator: "  |  ")
            add(preview, font: body, color: gray)
            out.append(NSAttributedString(string: "\n", attributes: [:]))
        }
        if let ctxT = resp["contextTranslation"] as? String, !ctxT.isEmpty {
            add("语境: " + ctxT, font: small, color: gray)
            out.append(NSAttributedString(string: "\n", attributes: [:]))
        }
        if let ranked = resp["rankedSenses"] as? [[String: Any]], ranked.count > 1 {
            let others = ranked.dropFirst().prefix(3).compactMap { $0["sense"] as? String }.joined(separator: " / ")
            if !others.isEmpty {
                add("其他义项: " + others, font: small, color: gray)
                out.append(NSAttributedString(string: "\n", attributes: [:]))
            }
        }
    }
    if let ctxS = resp["contextSentences"] as? String, !ctxS.isEmpty {
        let show = ctxS.count > 200 ? String(ctxS.prefix(200)) + "…" : ctxS
        add("原文: " + show, font: small, color: gray)
    }
    if let note = resp["note"] as? String, !note.isEmpty {
        add("\n(" + note + ")", font: small, color: orange)
    }
    return (out, copyText)
}

// 通用垃圾识别：复制保护通常输出单一符号反复重复（花括号/波浪线/等号…）
// PDF 等来源的换行归一化：句子中间的换行合并（中文直接去掉换行，英文补空格），空行(段落)保留
func normalizeWrappedText(_ text: String) -> String {
    let paragraphs = text.components(separatedBy: "\n\n")
    let sentEnders = CharacterSet(charactersIn: "。！？!?；;”\"…")
    return paragraphs.map { p -> String in
        let lines = p.components(separatedBy: "\n")
        guard lines.count > 1 else { return p }
        var out = lines[0]
        for i in 1..<lines.count {
            let prevLast = lines[i - 1].last
            let curFirst = lines[i].first
            let prevEndsSentence = prevLast.map { String($0).rangeOfCharacter(from: sentEnders) != nil } ?? true
            if prevEndsSentence {
                out += "\n"
            } else {
                let cjkPrev = prevLast.map { String($0).range(of: #"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]"#, options: .regularExpression) != nil } ?? false
                let cjkCur = curFirst.map { String($0).range(of: #"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]"#, options: .regularExpression) != nil } ?? false
                if cjkPrev && cjkCur {
                    // 中文断行：直接合并
                } else {
                    out += " "
                }
            }
            out += lines[i]
        }
        return out
    }.joined(separator: "\n\n")
}

func looksGarbled(_ text: String) -> Bool {
    let t = String(text)
    if t.count < 4 { return false }
    // 1) 任意单字符连续出现 10+ 次（===== ~~~~~ {{{{{ …）
    if let _ = t.range(of: #"(.)\1{9,}"#, options: .regularExpression) { return true }
    // 2) 高比例符号字符
    let suspicious = CharacterSet(charactersIn: "{}[]|~^`\\<>=")
    var bad = 0
    for ch in t.unicodeScalars where suspicious.contains(ch) { bad += 1 }
    if Double(bad) / Double(t.count) > 0.3 { return true }
    // 3) 超低多样性：长文本只含 ≤2 种字符（几乎必为垃圾）
    if t.count >= 16 && Set(t).count <= 2 { return true }
    return false
}

func showServerHint() {
    let msg = NSMutableAttributedString(string: "翻译服务未运行\n请先启动: node server.js",
        attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: attrColor(0xFBBF24)])
    popupPanel.show(attr: msg, copy: "", near: NSEvent.mouseLocation)
}

// MARK: - 自动拉起翻译服务（脱离终端常驻：助手自己保证服务可用）
func projectRoot() -> URL? {
    // 兼容两种布局：仓库根目录 或 打包后的 .app/Contents/Resources
    var url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("server.js").path) { return url }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Resources/server.js").path) {
            return url.appendingPathComponent("Resources")
        }
        url.deleteLastPathComponent()
    }
    return nil
}

func ensureServer() {
    guard let root = projectRoot() else { return }
    let sem = DispatchSemaphore(value: 0)
    var up = false
    let task = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:6688/api/stats")!) { _, resp, _ in
        if let r = resp as? HTTPURLResponse, r.statusCode == 200 { up = true }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 2)
    if up { return }
    // 服务未运行 → 在项目目录启动 node server.js（后台常驻，不依赖终端）
    // 优先使用与助手同目录的内置便携 node（打包版），再回退系统 node
    let bundledNode = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("node").path
    let nodePath = [bundledNode, "/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    let proc = Process()
    if let np = nodePath {
        proc.executableURL = URL(fileURLWithPath: np)
        proc.arguments = ["server.js"]
    } else {
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["node", "server.js"]
    }
    proc.currentDirectoryURL = root
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        debugLog("已自动启动翻译服务\n")
    } catch {
        debugLog("启动翻译服务失败: \(error)\n")
    }
}

// MARK: - 剪贴板监听
var popupPanel: PopupPanel!
var settingsPanel: SettingsPanel!
var statusItem: NSStatusItem!
var paused = false
// 剪贴板监听状态（全局，供复制按钮同步，避免反馈循环）
var monLastChange = NSPasteboard.general.changeCount
var monLastHandled = ""
var monLastTime = 0.0

func startMonitor() {
    debugLog("monitor 启动(剪贴板模式)\n")
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            if paused { continue }
            let pb = NSPasteboard.general
            let cc = pb.changeCount
            if cc == monLastChange { continue }
            monLastChange = cc
            guard let raw = pb.string(forType: .string), !raw.isEmpty, raw.count <= 3000 else { continue }
            let text = normalizeWrappedText(raw)   // PDF 断行合并
            let now = Date().timeIntervalSince1970
            // 同一内容 2 秒内重复复制不重复触发；超过 2 秒再次复制则重新显示
            if text == monLastHandled, now - monLastTime < 2.0 { continue }
            monLastHandled = text
            monLastTime = now

            // 疑似来源乱码（复制保护）→ 提示，不翻译
            if looksGarbled(text) {
                debugLog("剪贴板疑似乱码，跳过翻译: \(text.prefix(40))\n")
                DispatchQueue.main.async {
                    let msg = NSMutableAttributedString(
                        string: "⚠️ 复制内容疑似乱码\n（可能来自应用的复制保护，复制出来的就是花括号/乱码）\n建议改在其他地方复制，或手动输入",
                        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: attrColor(0xFBBF24)])
                    popupPanel.show(attr: msg, copy: "", near: NSEvent.mouseLocation)
                }
                continue
            }

            debugLog("剪贴板变化: \(text.prefix(40))\n")

            let context = bestEffortContext(selection: text)
            debugLog("上下文: \(context.isEmpty ? "无" : "\(context.count) 字符")\n")
            let resp = requestTranslation(selection: text, context: context, bounds: nil)
            DispatchQueue.main.async {
                if let resp = resp {
                    let (attr, copy) = buildAttributed(resp)
                    popupPanel.show(attr: attr, copy: copy, near: NSEvent.mouseLocation)
                } else {
                    showServerHint()
                }
            }
        }
    }
}

// MARK: - 入口
let args = CommandLine.arguments
debugMode = args.contains("--debug")

if args.contains("--check") {
    let pb = NSPasteboard.general
    let text = pb.string(forType: .string) ?? ""
    print("剪贴板当前文本: \(text.isEmpty ? "(空)" : text.prefix(60))")
    print("辅助功能(上下文用, 可选): \(AXIsProcessTrusted() ? "已授权 ✓" : "未授权（不影响 Cmd+C 翻译）")")
    if let app = NSWorkspace.shared.frontmostApplication {
        print("当前前台应用: \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
    }
    exit(0)
}

final class AppController: NSObject {
    @objc func openSettings() {
        settingsPanel.refreshLabels()
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel.makeKeyAndOrderFront(nil)
        settingsPanel.makeKey()
        settingsPanel.orderFrontRegardless()
        settingsPanel.center()
        // 显示后再布局，保证控件位置正确
        DispatchQueue.main.async { [weak self] in
            settingsPanel.resizeWindow()
        }
    }
    @objc func togglePause() {
        paused.toggle()
        (statusItem.menu?.items[1])?.title = paused ? "继续" : "暂停"
    }
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

popupPanel = PopupPanel()
settingsPanel = SettingsPanel()
let controller = AppController()

// 菜单栏图标（设置按钮）
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
if let btn = statusItem.button {
    btn.title = "喵"
    btn.font = NSFont.systemFont(ofSize: 13, weight: .bold)
}
let menu = NSMenu()
let settingsItem = NSMenuItem(title: "设置…", action: #selector(AppController.openSettings), keyEquivalent: ",")
settingsItem.target = controller
let pauseItem = NSMenuItem(title: "暂停", action: #selector(AppController.togglePause), keyEquivalent: "")
pauseItem.target = controller
let quitItem = NSMenuItem(title: "退出", action: #selector(AppController.quitApp), keyEquivalent: "q")
quitItem.target = controller
menu.addItem(settingsItem)
menu.addItem(pauseItem)
menu.addItem(.separator())
menu.addItem(quitItem)
statusItem.menu = menu

debugLog("启动\n")
ensureServer()          // 服务不在线时自动拉起（脱离终端也可用）
startMonitor()
app.run()
