import AppKit
import SnaprCore

/// What a click and drag on the canvas means right now.
///
/// Crop is a tool rather than a mode flag because it competes for the same
/// drag gesture as the six annotation kinds, and one enum makes that obvious.
enum EditorTool: Equatable, Sendable {
    case select
    case annotate(Annotation.Kind)
    case crop

    /// The single key that picks this tool.
    ///
    /// The annotation keys come from `Annotation.Kind.shortcut`, never from a
    /// second list, so the two cannot drift apart. Only the two tools that are
    /// not annotation kinds get a letter here.
    ///
    /// Crop is `x`, not `c`. `c` belongs to Counter. The annotation kinds get
    /// first pick of the letters because they are the tools people reach for
    /// constantly, and a test asserts these two never collide with them.
    static func forKey(_ key: String) -> EditorTool? {
        if let kind = Annotation.Kind.allCases.first(where: { $0.shortcut == key }) {
            return .annotate(kind)
        }
        switch key {
        case "x": return .crop
        case "v": return .select
        default: return nil
        }
    }
}

/// Which part of a slider drag a size change belongs to.
///
/// One drag of the knob sends dozens of values. Without this the editor would
/// checkpoint every one of them, so undoing a single drag would need forty
/// presses of Cmd+Z. The first event of a drag checkpoints and every later one
/// does not, which is the same rule the canvas already uses for a mouse drag.
enum SliderPhase: Equatable, Sendable {
    case dragBegan
    case dragContinued
    /// Not a drag: the keyboard, accessibility, or a programmatic change. It is
    /// a complete change on its own, so it is one undo step by itself.
    case single
}

/// The strip along the top of the editor window.
///
/// Plain AppKit controls in a stack view. No custom drawing, because the tool
/// buttons need to look and behave like buttons and nothing here is unusual
/// enough to earn its own control.
@MainActor
final class EditorToolbar: NSView {

    var onToolChanged: ((EditorTool) -> Void)?
    var onColourChanged: ((SRGB) -> Void)?
    var onSizeChanged: ((Int, SliderPhase) -> Void)?
    var onFillStyleChanged: ((Annotation.FillStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onSave: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomFit: (() -> Void)?

    private var toolButtons: [(tool: EditorTool, button: NSButton)] = []

    // These three are internal rather than private so a test can assert they
    // never take keyboard focus off the canvas, and can read back what the
    // toolbar is showing. Both failures are invisible in a screenshot.
    let colourWell = NSColorWell()
    let widthSlider = NSSlider()
    let fillControl = NSSegmentedControl()

    private let widthValue = NSTextField(labelWithString: "4")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    private let fillStyles = Annotation.FillStyle.allCases

    /// What the colour, size and fill controls will change. Nil means there is
    /// no selection, so they set the defaults for the next annotation instead.
    private var selectedKind: Annotation.Kind?
    private var currentTool: EditorTool = .select
    /// True between the first and the last event of one slider drag.
    private var widthDragActive = false

    /// The kind the style controls act on: what is selected, or failing that
    /// what the current tool will create next. Nil when neither is one of the
    /// annotation kinds, which is the plain Select and Crop case.
    private var effectiveKind: Annotation.Kind? {
        if let selectedKind { return selectedKind }
        if case .annotate(let kind) = currentTool { return kind }
        return nil
    }

    /// What the size slider means right now. Text has no line width and nothing
    /// else has a font size, so the one slider covers both.
    var sizeControl: Annotation.SizeControl {
        effectiveKind?.sizeControl ?? .lineWidth
    }

    init(colour: SRGB, lineWidth: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        wantsLayer = true
        buildControls(colour: colour, lineWidth: lineWidth)
    }

    required init?(coder: NSCoder) {
        fatalError("EditorToolbar is built in code, never from a nib")
    }

    // MARK: - Public state

    /// Highlights the tool buttons only. The controller always follows this
    /// with `showAttributes`, which is what the size slider needs, because
    /// switching to the text tool changes what that slider means.
    func setTool(_ tool: EditorTool) {
        currentTool = tool
        for entry in toolButtons {
            entry.button.state = (entry.tool == tool) ? .on : .off
        }
        updateFillEnabled()
    }

    /// Point the colour, size and fill controls at whatever the next change
    /// will affect: the selected annotation, or the defaults for the next one.
    ///
    /// Without this the toolbar can show red while a yellow box is selected,
    /// and the user cannot tell what the next click is going to do.
    func showAttributes(colour: SRGB,
                        lineWidth: Int,
                        fontSize: Int,
                        fillStyle: Annotation.FillStyle,
                        selectedKind: Annotation.Kind?) {
        self.selectedKind = selectedKind
        colourWell.color = AnnotationRenderer.nsColour(colour)
        if let i = fillStyles.firstIndex(of: fillStyle) {
            fillControl.selectedSegment = i
        }
        updateFillEnabled()

        let control = sizeControl
        let value = control == .fontSize ? fontSize : lineWidth
        // The range has to be set before the value. NSSlider clamps on the way
        // in, so writing a font size of 96 into a 1 to 40 slider would silently
        // become 40 and then be written back to the annotation as 40.
        widthSlider.minValue = Double(control.range.lowerBound)
        widthSlider.maxValue = Double(control.range.upperBound)
        widthSlider.toolTip = control.label
        widthSlider.setAccessibilityLabel(control.label)

        // Not while the knob is being dragged. The value here is rounded to a
        // whole pixel, so writing it back mid-drag makes the knob jump under
        // the mouse.
        if !widthDragActive {
            widthSlider.doubleValue = Double(control.clamp(value))
        }
        widthValue.stringValue = "\(value)"
    }

    func setZoom(_ zoom: CGFloat) {
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
    }

    func setUndoState(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    /// Border only or filled is only meaningful for a rectangle, so the control
    /// is disabled the rest of the time rather than left enabled and ignored. A
    /// control that visibly moves and changes nothing reads as a broken app.
    private func updateFillEnabled() {
        fillControl.isEnabled = (effectiveKind == .box)
    }

    // MARK: - Building

    private func buildControls(colour: SRGB, lineWidth: Int) {
        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 2

        addToolButton(.select, symbol: "cursorarrow", label: "Select", to: tools)
        for kind in Annotation.Kind.allCases {
            addToolButton(.annotate(kind), symbol: symbol(for: kind),
                          label: kind.label, to: tools)
        }
        addToolButton(.crop, symbol: "crop", label: "Crop", to: tools)

        colourWell.color = AnnotationRenderer.nsColour(colour)
        colourWell.target = self
        colourWell.action = #selector(colourChanged(_:))
        colourWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        colourWell.toolTip = "Annotation colour"

        buildWidthSlider(lineWidth: lineWidth)
        buildFillControl()

        configure(undoButton, symbol: "arrow.uturn.backward", label: "Undo",
                  action: #selector(undoTapped))
        configure(redoButton, symbol: "arrow.uturn.forward", label: "Redo",
                  action: #selector(redoTapped))
        undoButton.isEnabled = false
        redoButton.isEnabled = false

        let zoomOut = NSButton()
        configure(zoomOut, symbol: "minus.magnifyingglass", label: "Zoom out",
                  action: #selector(zoomOutTapped))
        let zoomIn = NSButton()
        configure(zoomIn, symbol: "plus.magnifyingglass", label: "Zoom in",
                  action: #selector(zoomInTapped))
        let zoomFit = NSButton()
        configure(zoomFit, symbol: "arrow.up.left.and.arrow.down.right",
                  label: "Fit", action: #selector(zoomFitTapped))

        // The percentage is shown because the whole point of the zoom is to let
        // the user look at real pixels, and they need to know when they are.
        zoomLabel.alignment = .center
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let copyButton = NSButton()
        configure(copyButton, symbol: "doc.on.doc", label: "Copy",
                  action: #selector(copyTapped))
        copyButton.toolTip = "Copy image  (⌘C)"
        let copyTextButton = NSButton()
        configure(copyTextButton, symbol: "text.viewfinder", label: "Copy text",
                  action: #selector(copyTextTapped))
        copyTextButton.toolTip = "Copy the text in this picture  (⇧⌘C)"
        let saveButton = NSButton()
        configure(saveButton, symbol: "square.and.arrow.down", label: "Save",
                  action: #selector(saveTapped))

        let spacerA = NSView()
        let spacerB = NSView()

        let row = NSStackView(views: [
            tools, separator(), colourWell, widthSlider, widthValue, fillControl,
            separator(), undoButton, redoButton,
            spacerA,
            zoomOut, zoomLabel, zoomIn, zoomFit,
            spacerB,
            separator(), copyTextButton, copyButton, saveButton
        ])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setTool(.select)
    }

    /// A continuous slider, not three fixed sizes.
    ///
    /// The old 2 / 4 / 8 buttons could not draw a hairline over small text or a
    /// thick marker over a whole toolbar, which is what people asked for. The
    /// range is set by `showAttributes`, because it depends on whether the
    /// slider is currently a line width or a text size.
    private func buildWidthSlider(lineWidth: Int) {
        widthSlider.minValue = Double(Annotation.SizeControl.lineWidth.range.lowerBound)
        widthSlider.maxValue = Double(Annotation.SizeControl.lineWidth.range.upperBound)
        widthSlider.doubleValue = Double(lineWidth)
        widthSlider.isContinuous = true
        widthSlider.controlSize = .small
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged(_:))
        // THE TRAP: by default a click on a slider makes it the first responder,
        // and every later single-key tool shortcut then goes to the slider
        // instead of the canvas. The keyboard flow dies silently after the user
        // touches the width once. Refusing first responder keeps focus where it
        // was, and the mouse still works because tracking does not need focus.
        widthSlider.refusesFirstResponder = true
        // The action must arrive on mouse up as well, so the value the user
        // released on is never lost when the drag is fast.
        _ = widthSlider.cell?.sendAction(on: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        widthSlider.toolTip = Annotation.SizeControl.lineWidth.label
        widthSlider.setAccessibilityLabel(Annotation.SizeControl.lineWidth.label)
        widthSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true

        // The number is shown because a size the user cannot read is a size
        // they cannot reproduce on the next screenshot. It also says which of
        // the two the slider is on right now: 4 is a line, 28 is type.
        widthValue.alignment = .center
        widthValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        widthValue.textColor = .secondaryLabelColor
        widthValue.stringValue = "\(lineWidth)"
        widthValue.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func buildFillControl() {
        fillControl.segmentCount = fillStyles.count
        fillControl.trackingMode = .selectOne
        for (i, style) in fillStyles.enumerated() {
            // A symbol, with the wording as the tooltip and the accessibility
            // label. Two text labels this long would push the zoom controls off
            // the end of a narrow window.
            if let image = NSImage(systemSymbolName: symbol(for: style),
                                   accessibilityDescription: style.label) {
                fillControl.setImage(image, forSegment: i)
            } else {
                fillControl.setLabel(style.label, forSegment: i)
            }
            fillControl.setWidth(32, forSegment: i)
        }
        fillControl.selectedSegment = 0
        fillControl.target = self
        fillControl.action = #selector(fillChanged(_:))
        fillControl.controlSize = .small
        // Same reason as the slider: the toolbar must never hold the keyboard.
        fillControl.refusesFirstResponder = true
        fillControl.toolTip = "Rectangle fill"
        fillControl.setAccessibilityLabel("Rectangle fill")
    }

    private func symbol(for kind: Annotation.Kind) -> String {
        switch kind {
        case .arrow:     return "arrow.up.right"
        case .box:       return "rectangle"
        case .text:      return "textformat"
        case .counter:   return "1.circle"
        case .blur:      return "square.grid.3x3.fill"
        case .highlight: return "highlighter"
        }
    }

    private func symbol(for style: Annotation.FillStyle) -> String {
        switch style {
        case .stroke: return "rectangle"
        case .filled: return "rectangle.fill"
        }
    }

    private func addToolButton(_ tool: EditorTool, symbol: String,
                               label: String, to stack: NSStackView) {
        let button = NSButton()
        configure(button, symbol: symbol, label: label, action: #selector(toolTapped(_:)))
        button.setButtonType(.pushOnPushOff)
        if case .annotate(let kind) = tool {
            button.toolTip = "\(label)  (\(kind.shortcut.uppercased()))"
        }
        stack.addArrangedSubview(button)
        toolButtons.append((tool, button))
    }

    private func configure(_ button: NSButton, symbol: String,
                           label: String, action: Selector) {
        // The symbol is the label. If a future macOS drops one of these names
        // the button falls back to text rather than becoming an invisible gap.
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = label
        }
        button.bezelStyle = .flexiblePush
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    // MARK: - Actions

    @objc private func toolTapped(_ sender: NSButton) {
        guard let entry = toolButtons.first(where: { $0.button === sender }) else { return }
        setTool(entry.tool)
        onToolChanged?(entry.tool)
    }

    @objc private func colourChanged(_ sender: NSColorWell) {
        onColourChanged?(AnnotationRenderer.srgb(sender.color))
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        // Whole pixels only. A line width of 6.4 cannot be reproduced by hand
        // and the renderer would round it anyway.
        let value = Int(sender.doubleValue.rounded())
        let phase = sliderPhase(for: NSApp.currentEvent?.type)
        widthValue.stringValue = "\(value)"
        onSizeChanged?(value, phase)
    }

    /// Works out which part of a drag this change is, from the event AppKit is
    /// currently processing.
    ///
    /// Separate from the action, and internal, because a unit test cannot fake
    /// `NSApp.currentEvent`. This is the part with the state in it, so this is
    /// the part worth testing.
    func sliderPhase(for eventType: NSEvent.EventType?) -> SliderPhase {
        switch eventType {
        case .leftMouseDown:
            widthDragActive = true
            return .dragBegan
        case .leftMouseDragged:
            // A click on the knob can send its first action only once the mouse
            // moves, so a drag can start here rather than on mouse down.
            let isFirst = !widthDragActive
            widthDragActive = true
            return isFirst ? .dragBegan : .dragContinued
        case .leftMouseUp:
            let wasDragging = widthDragActive
            widthDragActive = false
            // Nothing extra happens on mouse up. The checkpoint was already
            // taken at the start of the drag.
            return wasDragging ? .dragContinued : .single
        default:
            widthDragActive = false
            return .single
        }
    }

    @objc private func fillChanged(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard fillStyles.indices.contains(i) else { return }
        onFillStyleChanged?(fillStyles[i])
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func copyTextTapped() { onCopyText?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomFitTapped() { onZoomFit?() }
}
