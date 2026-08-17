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
    /// not annotation kinds get a letter here, and both avoid a, b, t, s, e, h.
    static func forKey(_ key: String) -> EditorTool? {
        if let kind = Annotation.Kind.allCases.first(where: { $0.shortcut == key }) {
            return .annotate(kind)
        }
        switch key {
        case "c": return .crop
        case "v": return .select
        default: return nil
        }
    }
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
    var onLineWidthChanged: ((Int) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomFit: (() -> Void)?

    private var toolButtons: [(tool: EditorTool, button: NSButton)] = []
    private let colourWell = NSColorWell()
    private let widthControl = NSSegmentedControl()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let undoButton = NSButton()
    private let redoButton = NSButton()

    /// The three line widths offered. Three named sizes beat a slider: a
    /// screenshot annotation is either thin, normal or thick.
    private let widths = [2, 4, 8]

    init(colour: SRGB, lineWidth: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        wantsLayer = true
        buildControls(colour: colour, lineWidth: lineWidth)
    }

    required init?(coder: NSCoder) {
        fatalError("EditorToolbar is built in code, never from a nib")
    }

    // MARK: - Public state

    func setTool(_ tool: EditorTool) {
        for entry in toolButtons {
            entry.button.state = (entry.tool == tool) ? .on : .off
        }
    }

    func setZoom(_ zoom: CGFloat) {
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
    }

    func setUndoState(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
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

        widthControl.segmentCount = widths.count
        widthControl.trackingMode = .selectOne
        for (i, w) in widths.enumerated() {
            widthControl.setLabel("\(w)", forSegment: i)
            widthControl.setWidth(30, forSegment: i)
        }
        widthControl.selectedSegment = widths.firstIndex(of: lineWidth) ?? 1
        widthControl.target = self
        widthControl.action = #selector(widthChanged(_:))
        widthControl.toolTip = "Line width"

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
        let saveButton = NSButton()
        configure(saveButton, symbol: "square.and.arrow.down", label: "Save",
                  action: #selector(saveTapped))

        let spacerA = NSView()
        let spacerB = NSView()

        let row = NSStackView(views: [
            tools, separator(), colourWell, widthControl,
            separator(), undoButton, redoButton,
            spacerA,
            zoomOut, zoomLabel, zoomIn, zoomFit,
            spacerB,
            separator(), copyButton, saveButton
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

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard widths.indices.contains(i) else { return }
        onLineWidthChanged?(widths[i])
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func zoomInTapped() { onZoomIn?() }
    @objc private func zoomOutTapped() { onZoomOut?() }
    @objc private func zoomFitTapped() { onZoomFit?() }
}
