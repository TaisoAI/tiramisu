import AppKit

/// Custom canvas-size dialog. Two integer fields (width × height), optional
/// aspect-ratio lock, range-checked, sets the document's canvas on Apply.
@MainActor
enum CanvasSizeDialog {
    /// UserDefaults key for remembering the last custom size used.
    private static let lastCustomKey = "world.hanley.tiramisu.canvas.lastCustom"

    static func present(store: DocumentStore) {
        let alert = NSAlert()
        alert.messageText = "Custom Canvas Size"
        alert.informativeText = "Pixels. Range: 16 to 16384 per side."

        // Recall last custom size, or use the current canvas as the default.
        let last = UserDefaults.standard.string(forKey: lastCustomKey)
        let defaults = (last?.split(separator: "x").compactMap { Int($0) } ?? [])
        let initialW = (defaults.count == 2 ? defaults[0] : Int(store.canvasSize.width))
        let initialH = (defaults.count == 2 ? defaults[1] : Int(store.canvasSize.height))

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let row = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let wLabel = NSTextField(labelWithString: "W")
        wLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let wField = NSTextField(string: String(initialW))
        wField.frame.size.width = 90
        wField.placeholderString = "1280"
        let xLabel = NSTextField(labelWithString: "×")
        xLabel.font = .systemFont(ofSize: 16, weight: .medium)
        xLabel.textColor = .secondaryLabelColor
        let hLabel = NSTextField(labelWithString: "H")
        hLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let hField = NSTextField(string: String(initialH))
        hField.frame.size.width = 90
        hField.placeholderString = "720"
        let pxLabel = NSTextField(labelWithString: "px")
        pxLabel.font = .systemFont(ofSize: 12)
        pxLabel.textColor = .secondaryLabelColor

        row.addArrangedSubview(wLabel)
        row.addArrangedSubview(wField)
        row.addArrangedSubview(xLabel)
        row.addArrangedSubview(hLabel)
        row.addArrangedSubview(hField)
        row.addArrangedSubview(pxLabel)
        row.frame.size.width = 360
        stack.addArrangedSubview(row)

        // Aspect-ratio lock toggle. Default off; when on, editing one field
        // recomputes the other from the initial ratio at the moment of toggle.
        let lockBox = NSButton(checkboxWithTitle: "Lock aspect ratio",
                                target: nil, action: nil)
        lockBox.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(lockBox)

        // Tiny live aspect-ratio readout below the fields.
        let aspectLabel = NSTextField(labelWithString: "")
        aspectLabel.font = .systemFont(ofSize: 11)
        aspectLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(aspectLabel)

        func updateAspect() {
            guard let w = Int(wField.stringValue), let h = Int(hField.stringValue),
                  w > 0, h > 0 else {
                aspectLabel.stringValue = ""
                return
            }
            let g = gcd(w, h)
            aspectLabel.stringValue = "\(w / g) : \(h / g)"
        }
        updateAspect()

        // Reflect aspect lock as the user types.
        let watcher = AspectWatcher(wField: wField, hField: hField, lockBox: lockBox,
                                     onChange: updateAspect)
        wField.target = watcher; wField.action = #selector(AspectWatcher.wChanged(_:))
        hField.target = watcher; hField.action = #selector(AspectWatcher.hChanged(_:))
        NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
                                                object: wField, queue: .main) { _ in watcher.wChanged(wField); updateAspect() }
        NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification,
                                                object: hField, queue: .main) { _ in watcher.hChanged(hField); updateAspect() }

        stack.frame.size = NSSize(width: 360, height: 100)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        // Focus the W field by default.
        DispatchQueue.main.async { wField.becomeFirstResponder(); wField.selectText(nil) }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let w = Int(wField.stringValue), let h = Int(hField.stringValue),
              (16...16384).contains(w), (16...16384).contains(h) else {
            let err = NSAlert()
            err.messageText = "Invalid size"
            err.informativeText = "Width and height must be integers from 16 to 16384."
            err.alertStyle = .warning
            err.runModal()
            return
        }
        UserDefaults.standard.set("\(w)x\(h)", forKey: lastCustomKey)
        tlog("canvas → custom \(w)×\(h)")
        store.canvasSize = CGSize(width: w, height: h)
        store.invalidate()
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}

/// Helper that maintains aspect lock when one field changes.
@MainActor
private final class AspectWatcher: NSObject {
    let wField: NSTextField
    let hField: NSTextField
    let lockBox: NSButton
    let onChange: () -> Void
    private var lockedRatio: Double?

    init(wField: NSTextField, hField: NSTextField, lockBox: NSButton, onChange: @escaping () -> Void) {
        self.wField = wField; self.hField = hField; self.lockBox = lockBox; self.onChange = onChange
        super.init()
    }

    private func snapshotRatioIfLocking() {
        if lockBox.state == .on {
            if lockedRatio == nil,
               let w = Double(wField.stringValue), let h = Double(hField.stringValue), w > 0, h > 0 {
                lockedRatio = w / h
            }
        } else {
            lockedRatio = nil
        }
    }

    @objc func wChanged(_ sender: Any) {
        snapshotRatioIfLocking()
        guard let r = lockedRatio, let w = Double(wField.stringValue), w > 0 else { return }
        let h = Int((w / r).rounded())
        if String(h) != hField.stringValue { hField.stringValue = String(h) }
    }

    @objc func hChanged(_ sender: Any) {
        snapshotRatioIfLocking()
        guard let r = lockedRatio, let h = Double(hField.stringValue), h > 0 else { return }
        let w = Int((h * r).rounded())
        if String(w) != wField.stringValue { wField.stringValue = String(w) }
    }
}
