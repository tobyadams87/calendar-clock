import AppKit
import ServiceManagement

// Calendar Clock: a menu bar calendar with a live clock (with seconds) at the top.
//
// Built to be lighter than Menu Bar Calendar, the app it replaces:
//  • plain AppKit throughout (no SwiftUI), with few objects: the month grid and the
//    month chooser are each one view that draws itself;
//  • no text fields anywhere, so macOS never loads its typing system into the app;
//  • the drop-down is built each time it opens and thrown away when it closes;
//  • the clock only ticks while the drop-down is open, so a closed app sits idle.

// MARK: - App

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var panel: CalendarPanel?
    private var clickMonitor: Any?
    private var lastClosed = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `open -a "Calendar Clock" --args --enable-login-item` turns on Open at Login.
        if CommandLine.arguments.contains("--enable-login-item") {
            LoginItem.enabled = true
        }
        // `open -a "Calendar Clock" --args --disable-login-item` turns it off again.
        if CommandLine.arguments.contains("--disable-login-item") {
            LoginItem.enabled = false
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "CalendarClock"   // remembers a ⌘-dragged position
        if #available(macOS 27.0, *) {
            // macOS 27 opens and closes the panel through "expanded interface" sessions, which keep the menu bar
            // chip highlighted while the panel is open (setting the highlight from code no longer shows) and
            // let the item take part in menu bar keyboard navigation.
            statusItem.expandedInterfaceDelegate = self
        } else if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
        }
        updateIcon()
        MenuBarIcon.onChange = { [weak self] in self?.updateIcon() }
        // Date styles change at midnight; these notifications cost nothing until they fire.
        NotificationCenter.default.addObserver(self, selector: #selector(updateIcon),
                                               name: .NSCalendarDayChanged, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateIcon),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func updateIcon() {
        DispatchQueue.main.async { [weak self] in
            if let button = self?.statusItem.button { MenuBarIcon.apply(to: button) }
        }
    }

    @objc private func toggle() {
        if panel != nil { close(); return }
        // The click that closed it (by taking focus away) shouldn't reopen it.
        if Date().timeIntervalSince(lastClosed) < 0.3 { return }
        open()
    }

    private func open() {
        guard let button = statusItem.button, let anchor = button.window?.frame else { return }
        let panel = CalendarPanel(anchor: anchor) { [weak self] in self?.close() }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        if #unavailable(macOS 27.0) {
            // Before macOS 27: this runs while the button is still tracking the click, and the button
            // un-highlights itself once that loop ends. Work queued for the default run-loop mode runs after it.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                if self?.panel != nil { button.highlight(true) }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.close()
        }
    }

    /// Closes the panel for any reason: Escape, a click elsewhere, clicking a day, or the icon again.
    private func close() {
        if #available(macOS 27.0, *) { statusItem.expandedInterfaceSession?.cancel() }   // un-highlights the chip
        tearDownPanel()
    }

    private func tearDownPanel() {
        guard let panel else { return }
        self.panel = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel.orderOut(nil)
        panel.tearDown()
        if #unavailable(macOS 27.0) { statusItem.button?.highlight(false) }
        lastClosed = Date()
        // Once the views have been freed, hand the freed pages back to macOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}

@available(macOS 27.0, *)
extension AppDelegate: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        // The click that closed the panel (by taking focus away) shouldn't reopen it.
        if panel != nil { return }
        if Date().timeIntervalSince(lastClosed) < 0.3 { session.cancel(); return }
        open()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        tearDownPanel()
    }
}

/// Menu bar icon, sized to match Menu Bar Calendar's.
let menuBarIcon: NSImage = {
    let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
    let image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar Clock")!
        .withSymbolConfiguration(config)!
    image.isTemplate = true
    return image
}()

/// The menu bar icon styles, chosen from the ⋯ menu and remembered between launches.
enum MenuBarIcon: String, CaseIterable {
    case appIcon, appGlyph, calendar, calendarWithDate, date, dayAndDate

    var title: String {
        switch self {
        case .appIcon: return "App Icon"
        case .appGlyph: return "App Icon Outline"
        case .calendar: return "Calendar"
        case .calendarWithDate: return "Calendar with Date"
        case .date: return "Date"
        case .dayAndDate: return "Day and Date"
        }
    }

    static var current: MenuBarIcon {
        get { MenuBarIcon(rawValue: UserDefaults.standard.string(forKey: "menuBarIcon") ?? "") ?? .appGlyph }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarIcon"); onChange?() }
    }
    static var onChange: (() -> Void)?

    private static let dayAndDateFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEd")
        return f
    }()

    /// What this style shows right now: an image for the icon styles, text for the others.
    var image: NSImage? {
        switch self {
        case .appIcon:
            let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            icon.size = NSSize(width: 20, height: 20)
            return icon
        case .appGlyph: return Self.appGlyphImage
        case .calendar: return menuBarIcon
        case .calendarWithDate: return Self.calendarIcon(day: Calendar.current.component(.day, from: Date()))
        case .date, .dayAndDate: return nil
        }
    }

    var text: String? {
        switch self {
        case .date: return String(Calendar.current.component(.day, from: Date()))
        case .dayAndDate: return Self.dayAndDateFormat.string(from: Date())
        default: return nil
        }
    }

    static func apply(to button: NSStatusBarButton) {
        button.image = current.image
        button.title = current.text ?? ""
        button.imagePosition = current.image == nil ? .noImage : .imageOnly
        button.setAccessibilityLabel("Calendar Clock")
    }

    /// The outline page with a header band, shared by the drawn template icons.
    private static func drawPage(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: true) { _ in
            let page = NSRect(x: 1.5, y: 1.5, width: 16, height: 15)
            let outline = NSBezierPath(roundedRect: page, xRadius: 3.5, yRadius: 3.5)
            NSColor.black.set()
            outline.lineWidth = 1.4
            outline.stroke()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            NSRect(x: page.minX, y: page.minY, width: page.width, height: 4).fill()   // header band
            NSGraphicsContext.restoreGraphicsState()
            draw(NSRect(x: page.minX, y: page.minY + 4, width: page.width, height: page.height - 4))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A calendar page with today's number on it.
    private static func calendarIcon(day: Int) -> NSImage {
        drawPage { area in
            let text = NSAttributedString(string: String(day), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.black])
            let size = text.size()
            text.draw(at: NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        }
    }

    /// The app icon as a one-colour outline: the calendar page with a clock at 10:10.
    private static let appGlyphImage: NSImage = drawPage { area in
        // Just the hands at 10:10, as on the full app icon, with a centre dot.
        let c = NSPoint(x: area.midX, y: area.midY + 0.3)
        func hand(_ degrees: CGFloat, _ length: CGFloat) {
            let a = degrees * .pi / 180   // clockwise from 12; the image is flipped (y down)
            let path = NSBezierPath()
            path.move(to: c)
            path.line(to: NSPoint(x: c.x + sin(a) * length, y: c.y - cos(a) * length))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.stroke()
        }
        hand(305, 3.4)   // hour
        hand(60, 4.6)    // minute
        NSBezierPath(ovalIn: NSRect(x: c.x - 1.1, y: c.y - 1.1, width: 2.2, height: 2.2)).fill()
    }
}

enum LoginItem {
    static var enabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }
}

/// Shared date formatters (created once, on first use).
enum Formats {
    private static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    static let time = make("jms")
    static let longDate = make("EEEEdMMMMy")
    static let month = make("MMMMy")
}

/// A view that draws itself on the CPU into an image and hands Core Animation the finished
/// image. Drawing text straight into an on-screen layer makes macOS set up GPU drawing inside
/// the app (compiling Metal shaders: a ~50 MB spike, with ~5 MB kept afterwards).
class ImageBackedView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func updateLayer() {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        guard let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: bounds.height)   // top-left origin, like the view
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { drawContent() }
        NSGraphicsContext.restoreGraphicsState()
        layer.contentsScale = scale
        layer.contents = ctx.makeImage()
    }

    /// Subclasses draw here, in view coordinates (top-left origin).
    func drawContent() {}
}

/// Draws a ‹ or › chevron as two strokes (cheaper than rendering a coloured SF Symbol).
func drawChevron(left: Bool, in rect: NSRect, colour: NSColor) {
    let x = rect.midX, y = rect.midY, dx: CGFloat = 2.5, dy: CGFloat = 5.5
    let path = NSBezierPath()
    path.move(to: NSPoint(x: left ? x + dx : x - dx, y: y - dy))
    path.line(to: NSPoint(x: left ? x - dx : x + dx, y: y))
    path.line(to: NSPoint(x: left ? x + dx : x - dx, y: y + dy))
    path.lineWidth = 2
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    colour.setStroke()
    path.stroke()
}

// MARK: - Drop-down window

/// A rounded, translucent panel hanging under the menu bar icon.
final class CalendarPanel: NSPanel, NSWindowDelegate {
    private let anchor: NSRect
    private let onClose: () -> Void
    private var calendarView: CalendarView?

    init(anchor: NSRect, onClose: @escaping () -> Void) {
        self.anchor = anchor
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: CalendarView.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        delegate = self

        let view = CalendarView()
        let background: NSView
        if #available(macOS 26.0, *) {
            // Liquid Glass, as Menu Bar Calendar uses: clearer than the older frosted material.
            // Inside a clear container clipped to the same rounded corners: on its own the glass
            // leaves a faint square behind them.
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            glass.contentView = view
            glass.autoresizingMask = [.width, .height]
            let container = NSView()
            container.wantsLayer = true   // clip to the glass's own rounded shape
            container.layer?.cornerRadius = 16
            container.layer?.cornerCurve = .continuous
            container.layer?.masksToBounds = true
            container.addSubview(glass)
            background = container
        } else {
            let frosted = NSVisualEffectView()
            frosted.material = .popover
            frosted.blendingMode = .behindWindow
            frosted.state = .active
            frosted.maskImage = roundedMask(radius: 14)
            frosted.addSubview(view)
            background = frosted
        }
        contentView = background
        calendarView = view

        // Size to the content and hang it under the icon.
        let size = NSSize(width: CalendarView.width, height: view.contentHeight)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height),
                 display: true)
        if background is NSVisualEffectView {
            view.frame = background.bounds
        } else {
            background.subviews.first?.frame = background.bounds   // the glass; it sizes its content view
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }   // follow the rounded shape
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {   // Esc: close the innermost thing open
        if calendarView?.handleEscape() != true { onClose() }
    }

    func windowDidResignKey(_ notification: Notification) { onClose() }

    /// Stop the clock and release every view.
    func tearDown() {
        calendarView?.stop()
        calendarView?.removeFromSuperview()
        calendarView = nil
        contentView = nil
        delegate = nil
    }
}

/// Stretchable rounded-rectangle mask for a blurred background.
func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// A copy of a template image filled with a colour (template images draw black otherwise).
func tinted(_ image: NSImage, _ colour: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: true) { rect in
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        colour.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// A transparent layer that reports any click on it.
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The ⋯ options, drawn to look like a standard menu.
final class OptionsMenuView: ImageBackedView {
    struct Item {
        let title: String
        let checked: Bool
        var leading: String? = nil     // drawn where the checkmark goes (e.g. ‹ for back)
        var trailing: String? = nil    // drawn at the right (e.g. › for a submenu)
        var image: NSImage? = nil      // a preview drawn before the title
        var detail: String? = nil      // grey text after the image/title (e.g. the style's name)
        let action: () -> Void
    }

    static let width: CGFloat = 200
    private static let rowHeight: CGFloat = 24, separatorHeight: CGFloat = 9, inset: CGFloat = 5
    private let rows: [Item?]   // nil draws a separator
    private var hover: Int?
    var onDone: (() -> Void)?

    init(rows: [Item?]) {
        self.rows = rows
        let height = rows.reduce(Self.inset * 2) { $0 + ($1 == nil ? Self.separatorHeight : Self.rowHeight) }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rowRect(_ i: Int) -> NSRect {
        var y = Self.inset
        for r in rows[..<i] { y += r == nil ? Self.separatorHeight : Self.rowHeight }
        return NSRect(x: Self.inset, y: y, width: bounds.width - Self.inset * 2,
                      height: rows[i] == nil ? Self.separatorHeight : Self.rowHeight)
    }

    private func hit(_ point: NSPoint) -> Int? {
        rows.indices.first { rows[$0] != nil && rowRect($0).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = hit(convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = hit(convert(event.locationInWindow, from: nil)), let item = rows[i] else { return }
        onDone?()
        DispatchQueue.main.async { item.action() }
    }

    private static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    }

    override func drawContent() {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Self.background.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        // Grey names line up in one column after the widest preview.
        let previewWidth = rows.compactMap { row -> CGFloat? in
            guard let row, row.detail != nil else { return nil }
            if let image = row.image { return image.size.width }
            return NSAttributedString(string: row.title, attributes: [.font: NSFont.menuFont(ofSize: 13)]).size().width
        }.max() ?? 0

        for (i, row) in rows.enumerated() {
            let r = rowRect(i)
            guard let row else {
                NSColor.separatorColor.setFill()
                NSRect(x: r.minX + 8, y: r.midY, width: r.width - 16, height: 1).fill()
                continue
            }
            let highlighted = i == hover
            if highlighted {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
            let colour: NSColor = highlighted ? .white : .labelColor
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: colour]
            let title = NSAttributedString(string: row.title, attributes: attrs)
            let h = title.size().height
            var x = r.minX + 22
            if let image = row.image {
                let size = image.size
                let dest = NSRect(x: x, y: r.midY - size.height / 2, width: size.width, height: size.height)
                if image.isTemplate {
                    tinted(image, colour).draw(in: dest)   // one-colour icons follow the text colour
                } else {
                    image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1,
                               respectFlipped: true, hints: nil)
                }
                x = dest.maxX + 8
            }
            if !row.title.isEmpty {
                title.draw(at: NSPoint(x: x, y: r.midY - h / 2))
                x += title.size().width + 8
            }
            if let detail = row.detail {
                x = r.minX + 22 + previewWidth + 10
                let grey: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
                NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: grey])
                    .draw(at: NSPoint(x: x, y: r.midY - h / 2 + 1))
            }
            if let trailing = row.trailing {
                let t = NSAttributedString(string: trailing, attributes: attrs)
                t.draw(at: NSPoint(x: r.maxX - 10 - t.size().width, y: r.midY - h / 2))
            }
            if let leading = row.leading {
                NSAttributedString(string: leading, attributes: attrs).draw(at: NSPoint(x: r.minX + 8, y: r.midY - h / 2))
            }
            if row.checked {
                NSAttributedString(string: "✓", attributes: attrs).draw(at: NSPoint(x: r.minX + 7, y: r.midY - h / 2))
            }
        }
    }
}

// MARK: - Drop-down content

final class CalendarView: NSView {
    static let width: CGFloat = 300
    private let pad: CGFloat = 14
    private let cal = Calendar.current

    private var month: Date
    private var today = Date()
    private(set) var contentHeight: CGFloat = 0
    private var timer: Timer?

    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private var prevButton: NSButton!
    private var todayButton: NSButton!
    private var nextButton: NSButton!
    private var moreButton: NSButton!
    private let grid: DayGridView
    private var chooser: MonthChooserView?   // month chooser: exists only while shown
    var isPicking: Bool { chooser != nil }

    override var isFlipped: Bool { true }

    init() {
        month = CalendarView.startOfMonth(Date(), Calendar.current)
        grid = DayGridView(width: Self.width - 28)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        autoresizingMask = [.width, .height]
        build()
        refreshClock()
        refreshGrid()
        layoutContent()
        startClock()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Building

    private func build() {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 36, weight: .medium)
        timeLabel.font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 36) } ?? base
        timeLabel.alignment = .center
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .center
        separator.boxType = .separator

        titleButton.isBordered = false
        titleButton.target = self
        titleButton.action = #selector(toggleChooser)
        titleButton.toolTip = "Choose a month and year"

        grid.onClick = { date in openInCalendar(date) }
        [timeLabel, dateLabel, separator, titleButton, grid].forEach(addSubview)

        prevButton = iconButton("chevron.left", size: 13, action: #selector(previousMonth), tip: "Previous month")
        todayButton = iconButton("circle.fill", size: 7, action: #selector(goToToday), tip: "Go to today")
        nextButton = iconButton("chevron.right", size: 13, action: #selector(nextMonth), tip: "Next month")
        moreButton = iconButton("ellipsis.circle", size: 15, weight: .regular, action: #selector(showMenu(_:)), tip: nil)
    }

    private func iconButton(_ symbol: String, size: CGFloat, weight: NSFont.Weight = .semibold,
                            action: Selector, tip: String?) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        addSubview(button)
        return button
    }

    // MARK: Layout (top-down, fixed width)

    private func layoutContent() {
        let w = Self.width
        let inner = w - pad * 2
        var y = pad

        timeLabel.frame = NSRect(x: pad, y: y, width: inner, height: 44); y += 44 + 2
        dateLabel.frame = NSRect(x: pad, y: y, width: inner, height: 16); y += 16 + 10
        separator.frame = NSRect(x: pad, y: y, width: inner, height: 1); y += 1 + 10

        let row: CGFloat = 22
        prevButton.frame = NSRect(x: pad - 2, y: y, width: 20, height: row)
        todayButton.frame = NSRect(x: pad + 20, y: y, width: 16, height: row)
        nextButton.frame = NSRect(x: pad + 38, y: y, width: 20, height: row)
        titleButton.frame = NSRect(x: (w - 150) / 2, y: y, width: 150, height: row)
        moreButton.frame = NSRect(x: w - pad - 22, y: y, width: 24, height: row)
        y += row + 10

        grid.frame = NSRect(x: pad, y: y, width: inner, height: DayGridView.height)
        y += DayGridView.height + pad

        contentHeight = y
    }

    // MARK: Clock

    /// Ticks on exact whole seconds, only while the drop-down exists.
    private func startClock() {
        let next = Date(timeIntervalSinceReferenceDate: ceil(Date().timeIntervalSinceReferenceDate))
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        refreshClock()
        if !cal.isDate(today, inSameDayAs: Date()) { refreshGrid() }   // past midnight
    }

    private func refreshClock() {
        let now = Date()
        timeLabel.stringValue = Formats.time.string(from: now)
        dateLabel.stringValue = Formats.longDate.string(from: now)
    }

    // MARK: Month grid

    private static func startOfMonth(_ date: Date, _ cal: Calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date))!
    }

    private func refreshGrid() {
        today = Date()
        titleButton.attributedTitle = NSAttributedString(
            string: Formats.month.string(from: month),
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor])

        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: month)!
        grid.days = (0..<42).map { i in
            let date = cal.date(byAdding: .day, value: i, to: start)!
            return DayGridView.Day(
                date: date,
                number: cal.component(.day, from: date),
                inMonth: cal.isDate(date, equalTo: month, toGranularity: .month),
                isWeekend: cal.isDateInWeekend(date),
                isToday: cal.isDate(date, inSameDayAs: today))
        }
    }

    @objc private func previousMonth() { show(cal.date(byAdding: .month, value: -1, to: month)!) }
    @objc private func nextMonth() { show(cal.date(byAdding: .month, value: 1, to: month)!) }
    @objc private func goToToday() { show(Self.startOfMonth(Date(), cal)) }

    private func show(_ newMonth: Date) {
        if isPicking { cancelPicking() }
        month = newMonth
        refreshGrid()
    }

    // MARK: ⋯ menu (drawn in the panel: a system NSMenu costs ~5 MB that's never given back)

    private var optionsOverlay: NSView?

    @objc private func showMenu(_ sender: NSButton) {
        if optionsOverlay != nil { dismissOptions(); return }
        presentMenu(iconStyles: false)
    }

    /// The ⋯ menu; "Menu Bar Icon ›" swaps it for the list of icon styles.
    private func presentMenu(iconStyles: Bool) {
        dismissOptions()
        let sender = moreButton!
        var rows: [OptionsMenuView.Item?]
        if iconStyles {
            rows = [.init(title: "Menu Bar Icon", checked: false, leading: "‹") { [weak self] in
                self?.presentMenu(iconStyles: false)
            }, nil]
            for style in MenuBarIcon.allCases {
                rows.append(.init(title: style.text ?? "", checked: MenuBarIcon.current == style,
                                  image: style.image, detail: style.title) { [weak self] in
                    MenuBarIcon.current = style
                    self?.presentMenu(iconStyles: true)   // stay open to try another
                })
            }
        } else {
            rows = [
                .init(title: "Menu Bar Icon", checked: false, trailing: "›") { [weak self] in
                    self?.presentMenu(iconStyles: true)
                },
                .init(title: "Open at Login", checked: LoginItem.enabled) { LoginItem.enabled.toggle() },
                nil,
                .init(title: "About Calendar Clock", checked: false) { showAbout() },
                .init(title: "Quit Calendar Clock", checked: false) { NSApp.terminate(nil) },
            ]
        }
        let menu = OptionsMenuView(rows: rows)
        menu.onDone = { [weak self] in self?.dismissOptions() }

        // A clear layer over everything: a click anywhere else just closes the menu.
        let catcher = ClickCatcher(frame: bounds)
        catcher.onClick = { [weak self] in self?.dismissOptions() }

        // Solid background drawn by the menu itself: a second blurred layer costs GPU memory.
        menu.setFrameOrigin(NSPoint(x: max(pad, sender.frame.maxX - menu.frame.width + 2), y: sender.frame.maxY + 4))
        catcher.addSubview(menu)
        addSubview(catcher)
        optionsOverlay = catcher
    }

    private func dismissOptions() {
        optionsOverlay?.removeFromSuperview()
        optionsOverlay = nil
    }

    /// Esc closes the menu, then the month chooser; returns false when there was neither.
    func handleEscape() -> Bool {
        if optionsOverlay != nil { dismissOptions(); return true }
        if let chooser, chooser.handleEscape() { return true }
        if isPicking { cancelPicking(); return true }
        return false
    }

    // MARK: Go to Date (month and year chooser, shown in place of the days)

    /// Clicking the month name opens the chooser; clicking it again closes it.
    @objc private func toggleChooser() {
        if isPicking { cancelPicking() } else { startPicking() }
    }

    private func startPicking() {
        guard !isPicking else { return }
        let c = cal.dateComponents([.year, .month], from: month)
        let now = cal.dateComponents([.year, .month], from: Date())
        let chooser = MonthChooserView(frame: grid.frame, year: c.year!, shown: (c.year!, c.month!),
                                       current: (now.year!, now.month!))
        chooser.onPick = { [weak self] year, monthNumber in
            guard let self else { return }
            self.show(self.cal.date(from: DateComponents(year: year, month: monthNumber, day: 1))!)
        }
        grid.isHidden = true
        addSubview(chooser)
        self.chooser = chooser
    }

    func cancelPicking() {
        chooser?.removeFromSuperview()
        chooser = nil
        grid.isHidden = false
    }
}

/// The weekday letters and six weeks of days, drawn by one view.
/// Today is filled and the day under the pointer gets a soft circle.
final class DayGridView: ImageBackedView, NSViewToolTipOwner {
    struct Day {
        let date: Date
        let number: Int
        let inMonth: Bool
        let isWeekend: Bool
        let isToday: Bool
    }

    static let headerHeight: CGFloat = 18      // weekday letters + gap
    static let rowStep: CGFloat = 32           // 30pt circle + 2pt gap
    static let height: CGFloat = headerHeight + 6 * rowStep - 2

    var days: [Day] = [] { didSet { needsDisplay = true } }
    var onClick: ((Date) -> Void)?
    private var hoverIndex: Int?
    private let colWidth: CGFloat
    private let weekdayLetters: [String]

    init(width: CGFloat) {
        colWidth = width / 7
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        weekdayLetters = Array(symbols[first...] + symbols[..<first])
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        // One tooltip region per cell; the text is only made when a tooltip actually shows.
        for i in 0..<42 { addToolTip(cellRect(i), owner: self, userData: nil) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cellRect(_ i: Int) -> NSRect {
        let col = CGFloat(i % 7), row = CGFloat(i / 7)
        return NSRect(x: col * colWidth + (colWidth - 30) / 2, y: Self.headerHeight + row * Self.rowStep,
                      width: 30, height: 30)
    }

    private func index(at point: NSPoint) -> Int? {
        guard point.y >= Self.headerHeight, point.x >= 0 else { return nil }
        let col = Int(point.x / colWidth), row = Int((point.y - Self.headerHeight) / Self.rowStep)
        guard col < 7, row < 6 else { return nil }
        let i = row * 7 + col
        return cellRect(i).contains(point) && i < days.count ? i : nil
    }

    private func setHover(_ i: Int?) {
        guard i != hoverIndex else { return }
        let old = hoverIndex
        hoverIndex = i
        if let old { setNeedsDisplay(cellRect(old)) }
        if let i { setNeedsDisplay(cellRect(i)) }
    }

    override func mouseMoved(with event: NSEvent) { setHover(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClick?(days[i].date) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).map { Formats.longDate.string(from: days[$0].date) } ?? ""
    }

    override func drawContent() {
        // Weekday letters
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        for (i, letter) in weekdayLetters.enumerated() {
            let text = NSAttributedString(string: letter, attributes: headerAttrs)
            let size = text.size()
            text.draw(at: NSPoint(x: CGFloat(i) * colWidth + (colWidth - size.width) / 2, y: 0))
        }

        // Days
        let regular = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        for (i, day) in days.enumerated() {
            let rect = cellRect(i)
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            if day.isToday {
                NSColor.controlAccentColor.setFill(); circle.fill()
            } else if i == hoverIndex {
                NSColor.labelColor.withAlphaComponent(0.08).setFill(); circle.fill()
            }
            let colour: NSColor = day.isToday ? .white
                : !day.inMonth ? .tertiaryLabelColor
                : day.isWeekend ? .secondaryLabelColor : .labelColor
            let text = NSAttributedString(string: "\(day.number)", attributes: [
                .font: day.isToday ? bold : regular, .foregroundColor: colour])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }
}

/// Month chooser (click the month name), drawn by one view. Two levels:
///  • months: the year with ‹ › arrows over a grid of the twelve months;
///  • years (click the year): twelve years in the same grid, with ‹ › moving twelve at a time.
/// The current month/year is filled and the one on show is ringed.
final class MonthChooserView: ImageBackedView {
    private var year: Int
    private var pickingYear = false
    private var pageStart: Int              // first year in the year grid
    private let shown: (year: Int, month: Int)
    private let current: (year: Int, month: Int)
    var onPick: ((Int, Int) -> Void)?
    private var hover: Int?   // 0–11 grid cells, 12 previous, 13 next, 14 title
    private let names = Calendar.current.shortStandaloneMonthSymbols
    private static let headerRow: CGFloat = 36

    init(frame: NSRect, year: Int, shown: (Int, Int), current: (Int, Int)) {
        self.year = year
        self.pageStart = year - 4   // the year sits in the middle of the grid
        self.shown = shown
        self.current = current
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Esc in the year grid goes back to the months; returns false when already there.
    func handleEscape() -> Bool {
        guard pickingYear else { return false }
        pickingYear = false
        needsDisplay = true
        return true
    }

    private func rect(_ i: Int) -> NSRect {
        switch i {
        case 12: return NSRect(x: 0, y: 4, width: 36, height: 28)
        case 13: return NSRect(x: bounds.width - 36, y: 4, width: 36, height: 28)
        case 14: return NSRect(x: bounds.midX - 70, y: 4, width: 140, height: 28)
        default:
            let colWidth = bounds.width / 3
            let rowHeight = (bounds.height - Self.headerRow) / 4
            return NSRect(x: CGFloat(i % 3) * colWidth + 6,
                          y: Self.headerRow + CGFloat(i / 3) * rowHeight + (rowHeight - 30) / 2,
                          width: colWidth - 12, height: 30)
        }
    }

    private func hit(_ point: NSPoint) -> Int? { (0...14).first { rect($0).contains(point) } }

    private func setHover(_ i: Int?) {
        guard i != hover else { return }
        hover = i
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { setHover(hit(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = hit(convert(event.locationInWindow, from: nil)) else { return }
        switch (i, pickingYear) {
        case (12, false): year -= 1
        case (13, false): year += 1
        case (12, true): pageStart -= 12
        case (13, true): pageStart += 12
        case (14, false): pickingYear = true; pageStart = year - 4
        case (14, true): pickingYear = false
        case (_, true): year = pageStart + i; pickingYear = false
        default: onPick?(year, i + 1); return
        }
        needsDisplay = true
    }

    override func drawContent() {
        let soft = NSColor.labelColor.withAlphaComponent(0.08)

        // Title (the year, or the range of years) and arrows
        let title = pickingYear ? "\(pageStart) – \(pageStart + 11)" : String(year)
        if hover == 14 {
            soft.setFill()
            NSBezierPath(roundedRect: rect(14), xRadius: 8, yRadius: 8).fill()
        }
        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let ts = titleText.size()
        titleText.draw(at: NSPoint(x: bounds.midX - ts.width / 2, y: rect(14).midY - ts.height / 2))
        for (i, left) in [(12, true), (13, false)] {
            if hover == i {
                soft.setFill()
                NSBezierPath(roundedRect: rect(i).insetBy(dx: 4, dy: 0), xRadius: 8, yRadius: 8).fill()
            }
            drawChevron(left: left, in: rect(i), colour: .secondaryLabelColor)
        }

        // Grid: months, or twelve years
        for i in 0..<12 {
            let r = rect(i)
            let label: String, isCurrent: Bool, isShown: Bool
            if pickingYear {
                let y = pageStart + i
                label = String(y)
                isCurrent = y == current.year
                isShown = y == year
            } else {
                label = names[i]
                isCurrent = year == current.year && i + 1 == current.month
                isShown = year == shown.year && i + 1 == shown.month
            }
            let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 15, yRadius: 15)
            if isCurrent {
                NSColor.controlAccentColor.setFill(); pill.fill()
            } else if hover == i {
                soft.setFill(); pill.fill()
            }
            if isShown && !isCurrent {
                NSColor.controlAccentColor.setStroke(); pill.lineWidth = 1.5; pill.stroke()
            }
            let text = NSAttributedString(string: label, attributes: [
                .font: pickingYear
                    ? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular)
                    : NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular),
                .foregroundColor: isCurrent ? NSColor.white : NSColor.labelColor])
            let s = text.size()
            text.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }
}

// MARK: - Actions

/// Shows the clicked day in the Calendar app (day view).
/// Opens Calendar, then sends it Calendar's own "switch view" and "view calendar" Apple events
/// directly (codes from Calendar's scripting dictionary; no AppleScript, which macOS refused
/// even with permission). Needs the "control Calendar" Automation permission: the check below
/// shows macOS's prompt once; if it's refused, Calendar still opens, just on its current view.
func openInCalendar(_ date: Date) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
        // Off the main thread: the permission check can wait for the prompt to be answered.
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal")
            let status = target.aeDesc.map {
                AEDeterminePermissionToAutomateTarget($0, fourCC("wrbt"), fourCC("aeca"), true)
            } ?? OSStatus(procNotFound)
            guard status == noErr else {
                NSLog("CalendarClock: not allowed to control Calendar (%d)", status)
                return
            }
            // Midday avoids landing on the wrong day near midnight or across time zones.
            let midday = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            do {
                try sendCalendarEvent("aeca", parameter: "wre5", NSAppleEventDescriptor(enumCode: fourCC("E5da")))
                try sendCalendarEvent("aec9", parameter: "wtdt", NSAppleEventDescriptor(date: midday))
            } catch {
                NSLog("CalendarClock: Calendar didn't accept the request: %@", error.localizedDescription)
            }
        }
    }
}

/// Sends one of Calendar's own commands (event class "wrbt") with a single parameter.
private func sendCalendarEvent(_ id: String, parameter key: String, _ value: NSAppleEventDescriptor) throws {
    let event = NSAppleEventDescriptor(
        eventClass: fourCC("wrbt"), eventID: fourCC(id),
        targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.iCal"),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(value, forKeyword: fourCC(key))
    _ = try event.sendEvent(options: [.waitForReply], timeout: 5)
}

/// Standard About window, with the app icon and a short credit.
func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let credits = NSAttributedString(
        string: "A menu bar calendar with a clock that shows seconds.\nWith thanks to Menu Bar Calendar, which inspired it.",
        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
}

/// A four-character Apple event code from a string such as "wrbt".
func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
