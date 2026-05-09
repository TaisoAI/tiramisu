import SwiftUI
import AppKit

struct TransformOverlay: View {
    @Environment(DocumentStore.self) private var store
    let docToView: CGFloat
    let imageOrigin: CGPoint    // top-left of the canvas image in this view's coords

    @State private var dragStart: DragStart?
    @State private var missStart: CGPoint?
    @State private var tatStart: TATStart?
    @State private var paintStroke: PaintStroke?
    /// Lasso polyline in doc top-down coords. Recorded as the user drags;
    /// closed and converted to a CGPath on mouse-up.
    @State private var lassoPoints: [CGPoint] = []
    /// Polygonal lasso vertices in doc top-down coords. Each click adds a
    /// vertex; double-click (or click near the start) closes the polygon.
    /// Distinct from `lassoPoints` because the interaction model is
    /// click-by-click instead of drag.
    @State private var polyLassoVertices: [CGPoint] = []
    @State private var lastPolyClickAt: Date?
    @State private var lastPolyClickDoc: CGPoint?
    /// Live pointer position in this overlay's view coords. Tracked via the
    /// AppKit `MouseTracker` background so the SwiftUI Canvas can draw a
    /// brush-radius preview circle at the cursor — far more reliable than
    /// fighting NSCursor's image-size quirks at large brush sizes.
    @State private var hoverPoint: CGPoint?

    private struct DragStart {
        enum Kind { case move, cornerTL, cornerTR, cornerBL, cornerBR, rotate }
        let kind: Kind
        let startCenter: CGPoint
        let startScaleX: Double
        let startScaleY: Double
        let startRotation: Double
        let startMouseDoc: CGPoint
    }

    /// Snapshot of the HSL TAT click — captured on mouse-down so the drag
    /// applies a consistent delta to the bands the click landed on.
    private struct TATStart {
        let startMouseY: CGFloat
        let channel: HSLTATChannel
        /// Up to two band indices (into HSLAdjustments' fixed band order)
        /// with weights summing to 1.
        let bandWeights: [(idx: Int, weight: Double)]
        /// Each affected band's slider value at the moment of click; we
        /// add `delta * weight` to this throughout the drag.
        let startValues: [Int: Double]
    }

    var body: some View {
        Canvas { ctx, size in
            // Active selection — render as marching ants. Works for both
            // rectangular (marquee) and free-form (lasso) selections by
            // walking the stored CGPath and transforming to view coords.
            if let sel = store.selectionPath {
                let viewPath = pathToView(sel)
                ctx.stroke(viewPath, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                ctx.stroke(viewPath, with: .color(.black),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4], dashPhase: 4))
            }
            // In-flight lasso: trace the polyline as the user drags.
            if store.tool == .lasso, lassoPoints.count >= 2 {
                var p = Path()
                let first = lassoPoints[0]
                p.move(to: CGPoint(x: first.x * docToView + imageOrigin.x,
                                   y: first.y * docToView + imageOrigin.y))
                for pt in lassoPoints.dropFirst() {
                    p.addLine(to: CGPoint(x: pt.x * docToView + imageOrigin.x,
                                          y: pt.y * docToView + imageOrigin.y))
                }
                ctx.stroke(p, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                ctx.stroke(p, with: .color(.black),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4], dashPhase: 4))
            }
            // In-flight polygonal lasso: committed vertices as solid edges,
            // plus a "rubber band" line from the last vertex to the cursor.
            if store.tool == .polygonalLasso, !polyLassoVertices.isEmpty {
                var p = Path()
                let first = polyLassoVertices[0]
                p.move(to: CGPoint(x: first.x * docToView + imageOrigin.x,
                                   y: first.y * docToView + imageOrigin.y))
                for v in polyLassoVertices.dropFirst() {
                    p.addLine(to: CGPoint(x: v.x * docToView + imageOrigin.x,
                                          y: v.y * docToView + imageOrigin.y))
                }
                if let h = hoverPoint {
                    p.addLine(to: h)
                }
                ctx.stroke(p, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                ctx.stroke(p, with: .color(.black),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4], dashPhase: 4))
                // Vertex dots.
                for v in polyLassoVertices {
                    let r = CGRect(x: v.x * docToView + imageOrigin.x - 2.5,
                                   y: v.y * docToView + imageOrigin.y - 2.5,
                                   width: 5, height: 5)
                    ctx.fill(Path(ellipseIn: r), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: r), with: .color(.black), lineWidth: 0.75)
                }
            }

            guard let layer = store.activeLayer else { return }

            if store.tool == .move {
                if let smart = layer.smart {
                    drawBBox(ctx, bboxDoc(smart: smart))
                } else if layer.kind == .text, let b = textBBoxDoc(layer: layer) {
                    drawBBox(ctx, b)
                }
            }

            // Brush preview ring — drawn inside the SwiftUI Canvas so the
            // size is always pixel-exact relative to the rendered stamp,
            // unlike NSCursor which the OS scales/clips on its own.
            if (store.tool == .pencil || store.tool == .eraser),
               let p = hoverPoint, store.hslTATChannel == nil {
                let d = max(2, CGFloat(store.brush.size) * docToView)
                let rect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(.white.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.25))
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(.black.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 0.75))
            }

            if store.tool == .relight && layer.relight.enabled {
                // Draw the key-light position as a ringed target at the UV center.
                let px = imageOrigin.x + layer.relight.position.x * store.canvasSize.width * docToView
                let py = imageOrigin.y + layer.relight.position.y * store.canvasSize.height * docToView
                let ringR = max(10, layer.relight.radius * max(store.canvasSize.width, store.canvasSize.height) * docToView * 0.45)
                ctx.stroke(Path(ellipseIn: CGRect(x: px - ringR, y: py - ringR, width: ringR * 2, height: ringR * 2)),
                           with: .color(.yellow.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                // Crosshair
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: px - 12, y: py))
                    p.addLine(to: CGPoint(x: px + 12, y: py))
                    p.move(to: CGPoint(x: px, y: py - 12))
                    p.addLine(to: CGPoint(x: px, y: py + 12))
                }, with: .color(.yellow), lineWidth: 1.5)
                let hub = CGRect(x: px - 4, y: py - 4, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: hub), with: .color(.yellow))
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        // Crosshair cursor + Esc-to-exit when HSL TAT mode is active.
        // Without the cursor change users can't tell they're in a different
        // interaction mode; without Esc the only way out is the scope
        // button on the panel which may be off-screen during a drag session.
        .background(ToolCursorOverlay(
            tool: store.tool,
            tatActive: store.hslTATChannel != nil
        ))
        .background(MouseTracker { p in hoverPoint = p })
        .background(TATKeyHandler(active: store.hslTATChannel != nil) {
            store.hslTATChannel = nil
        })
        // Esc cancels an in-flight polygonal lasso without committing.
        .background(TATKeyHandler(active: !polyLassoVertices.isEmpty) {
            polyLassoVertices = []
            lastPolyClickAt = nil
            lastPolyClickDoc = nil
        })
    }

    /// Doc-coord (top-down) CGPath → SwiftUI view-coord Path for drawing.
    private func pathToView(_ doc: CGPath) -> Path {
        var t = CGAffineTransform(scaleX: docToView, y: docToView)
            .concatenating(CGAffineTransform(translationX: imageOrigin.x, y: imageOrigin.y))
        guard let mapped = doc.copy(using: &t) else { return Path(doc) }
        return Path(mapped)
    }

    private func bboxDoc(smart: SmartSource) -> CGRect {
        let w = Double(smart.pixelWidth) * abs(smart.scaleX)
        let h = Double(smart.pixelHeight) * abs(smart.scaleY)
        return CGRect(x: smart.centerX - w / 2,
                      y: smart.centerY - h / 2,
                      width: w, height: h)
    }

    private func textBBoxDoc(layer: PXLayer) -> CGRect? {
        var b = layer.text.lastRenderedBounds
        guard b.width > 0 && b.height > 0 else { return nil }
        // lastRenderedBounds is stored assuming anchor = (0.5, 0.5) AND
        // offset = (0, 0). The renderer applies both as a translation at
        // composite time (see LayerRenderer.composite), so we have to
        // mirror that here so the bbox tracks where the text actually drew.
        let dx = (layer.text.anchorX - 0.5) * store.canvasSize.width + layer.offset.width
        let dy = (layer.text.anchorY - 0.5) * store.canvasSize.height + layer.offset.height
        b.origin.x += dx
        b.origin.y += dy
        return b
    }

    private func drawBBox(_ ctx: GraphicsContext, _ bDoc: CGRect) {
        let rect = CGRect(x: bDoc.minX * docToView + imageOrigin.x,
                          y: bDoc.minY * docToView + imageOrigin.y,
                          width: bDoc.width * docToView,
                          height: bDoc.height * docToView)
        ctx.stroke(Path(rect),
                   with: .color(.accentColor),
                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        for pt in handlePoints(in: rect) {
            let r = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: r), with: .color(.white))
            ctx.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    private func handlePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let docP = CGPoint(x: (value.location.x - imageOrigin.x) / docToView,
                                   y: (value.location.y - imageOrigin.y) / docToView)

                // HSL Targeted Adjustment Tool — runs before any tool branch
                // so it works regardless of the active sidebar tool. Click
                // anywhere on the photo, drag up/down to scrub the band(s)
                // under the cursor for the active sub-tab.
                if let tatChan = store.hslTATChannel {
                    handleTATDrag(value: value, docP: docP, channel: tatChan)
                    return
                }

                if store.tool == .pencil || store.tool == .eraser {
                    handlePaintDrag(docP: docP, eraser: store.tool == .eraser)
                    return
                }

                if store.tool == .marquee {
                    // Drag draws a selection rect. Start point = where missStart was set.
                    if missStart == nil { missStart = value.location }
                    let startDoc = CGPoint(
                        x: ((missStart?.x ?? value.location.x) - imageOrigin.x) / docToView,
                        y: ((missStart?.y ?? value.location.y) - imageOrigin.y) / docToView
                    )
                    let x1 = min(startDoc.x, docP.x), y1 = min(startDoc.y, docP.y)
                    let x2 = max(startDoc.x, docP.x), y2 = max(startDoc.y, docP.y)
                    store.setSelection(rect: CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
                    return
                }

                if store.tool == .polygonalLasso {
                    // Polygonal lasso is click-by-click; the rubber band
                    // is driven by hoverPoint, not by drag events. Just
                    // consume drag-changed updates.
                    return
                }

                if store.tool == .lasso {
                    if lassoPoints.isEmpty { lassoPoints.append(docP) }
                    // Append a new sample only if it's moved meaningfully —
                    // keeps the polyline cheap on long drags without losing
                    // shape detail.
                    if let last = lassoPoints.last,
                       hypot(docP.x - last.x, docP.y - last.y) > 1.5 / docToView {
                        lassoPoints.append(docP)
                    }
                    return
                }

                if store.tool == .relight {
                    if let layer = store.activeLayer {
                        if dragStart == nil { store.checkpoint("Move Key Light") }
                        let u = max(0, min(1, docP.x / store.canvasSize.width))
                        let v = max(0, min(1, docP.y / store.canvasSize.height))
                        layer.relight.position = CGPoint(x: u, y: v)
                        if !layer.relight.enabled { layer.relight.enabled = true }
                        // Mark as "in gesture" so onEnded knows not to deselect.
                        dragStart = dragStart ?? DragStart(kind: .move,
                                                          startCenter: .zero,
                                                          startScaleX: 0, startScaleY: 0,
                                                          startRotation: 0,
                                                          startMouseDoc: docP)
                        store.invalidate()
                    }
                    return
                }

                guard store.tool == .move else { return }

                // If we haven't started manipulating yet, figure out WHAT the user clicked.
                if dragStart == nil {
                    if let active = store.activeLayer {
                        // Smart layer: handles + bbox
                        if let smart = active.smart,
                           let kind = hitTestOrNil(smart: smart, atDoc: docP) {
                            store.checkpoint(kind == .move ? "Move" : "Scale")
                            dragStart = makeStart(kind: kind, smart: smart, at: docP)
                            return
                        }
                        // Text layer: bbox from cached render
                        if active.kind == .text,
                           let kind = hitTestTextOrNil(layer: active, atDoc: docP) {
                            store.checkpoint(kind == .move ? "Move Text" : "Resize Text")
                            dragStart = DragStart(
                                kind: kind,
                                startCenter: CGPoint(x: active.text.anchorX * store.canvasSize.width,
                                                     y: active.text.anchorY * store.canvasSize.height),
                                startScaleX: active.text.fontSize,
                                startScaleY: active.text.fontSize,
                                startRotation: 0,
                                startMouseDoc: docP
                            )
                            return
                        }
                    }
                    // Scan all layers top-to-bottom to pick one on click.
                    for L in store.layers.reversed() {
                        guard L.visible else { continue }
                        if let smart = L.smart,
                           bboxDoc(smart: smart).insetBy(dx: -6 / docToView, dy: -6 / docToView).contains(docP) {
                            store.activeLayerID = L.id
                            store.checkpoint("Move")
                            dragStart = makeStart(kind: .move, smart: smart, at: docP)
                            return
                        }
                        if L.kind == .text,
                           let tb = textBBoxDoc(layer: L),
                           tb.insetBy(dx: -6 / docToView, dy: -6 / docToView).contains(docP) {
                            store.activeLayerID = L.id
                            store.checkpoint("Move Text")
                            dragStart = DragStart(
                                kind: .move,
                                startCenter: CGPoint(x: L.text.anchorX * store.canvasSize.width,
                                                     y: L.text.anchorY * store.canvasSize.height),
                                startScaleX: L.text.fontSize,
                                startScaleY: L.text.fontSize,
                                startRotation: 0,
                                startMouseDoc: docP
                            )
                            return
                        }
                    }
                    if missStart == nil { missStart = value.location }
                    return
                }

                // Apply the in-progress drag.
                guard let layer = store.activeLayer, let s = dragStart else { return }
                let dx = docP.x - s.startMouseDoc.x
                let dy = docP.y - s.startMouseDoc.y

                // Text layer mutations
                if layer.kind == .text && layer.smart == nil {
                    switch s.kind {
                    case .move:
                        let nx = s.startCenter.x + dx
                        let ny = s.startCenter.y + dy
                        layer.text.anchorX = nx / store.canvasSize.width
                        layer.text.anchorY = ny / store.canvasSize.height
                    case .cornerTL, .cornerTR, .cornerBL, .cornerBR:
                        // Resize font size based on distance-from-center ratio.
                        let startR = max(hypot(s.startMouseDoc.x - s.startCenter.x,
                                               s.startMouseDoc.y - s.startCenter.y), 0.0001)
                        let newR = hypot(docP.x - s.startCenter.x, docP.y - s.startCenter.y)
                        let r = newR / startR
                        layer.text.fontSize = max(6, min(1200, s.startScaleX * Double(r)))
                    case .rotate: break
                    }
                    store.invalidate()
                    return
                }

                // Smart layer mutations
                guard var smart = layer.smart else { return }
                switch s.kind {
                case .move:
                    smart.centerX = s.startCenter.x + dx
                    smart.centerY = s.startCenter.y + dy
                case .cornerTL, .cornerTR, .cornerBL, .cornerBR:
                    let startDx = s.startMouseDoc.x - s.startCenter.x
                    let startDy = s.startMouseDoc.y - s.startCenter.y
                    let newDx = docP.x - s.startCenter.x
                    let newDy = docP.y - s.startCenter.y
                    let shift = NSEvent.modifierFlags.contains(.shift)
                    if shift {
                        let rx = startDx == 0 ? 1 : newDx / startDx
                        let ry = startDy == 0 ? 1 : newDy / startDy
                        smart.scaleX = max(0.02, abs(s.startScaleX * Double(rx)))
                        smart.scaleY = max(0.02, abs(s.startScaleY * Double(ry)))
                    } else {
                        let startR = max(hypot(startDx, startDy), 0.0001)
                        let newR = hypot(newDx, newDy)
                        let r = newR / startR
                        smart.scaleX = max(0.02, s.startScaleX * Double(r))
                        smart.scaleY = max(0.02, s.startScaleY * Double(r))
                    }
                case .rotate:
                    break
                }
                layer.smart = smart
                store.invalidate()
            }
            .onEnded { value in
                if store.tool == .pencil || store.tool == .eraser {
                    paintStroke?.endStroke()
                    paintStroke?.commitToLayer()
                    paintStroke = nil
                    store.endCoalescing()
                    store.invalidate()
                    return
                }
                if store.tool == .marquee {
                    // Tap with no drag clears the selection.
                    if let start = missStart, hypot(value.location.x - start.x, value.location.y - start.y) < 4 {
                        store.clearSelection()
                    }
                    missStart = nil
                    return
                }
                if store.tool == .lasso {
                    // Need at least 3 distinct points to define a region.
                    // Anything shorter = treat as a deselect tap.
                    if lassoPoints.count < 3 {
                        store.clearSelection()
                    } else {
                        let p = CGMutablePath()
                        p.move(to: lassoPoints[0])
                        for pt in lassoPoints.dropFirst() { p.addLine(to: pt) }
                        p.closeSubpath()
                        store.setSelection(path: p)
                    }
                    lassoPoints = []
                    return
                }

                if store.tool == .magicWand {
                    let docP = CGPoint(x: (value.location.x - imageOrigin.x) / docToView,
                                       y: (value.location.y - imageOrigin.y) / docToView)
                    handleMagicWand(at: docP)
                    return
                }

                if store.tool == .smartSelect {
                    let docP = CGPoint(x: (value.location.x - imageOrigin.x) / docToView,
                                       y: (value.location.y - imageOrigin.y) / docToView)
                    handleSmartSelect(at: docP)
                    return
                }

                if store.tool == .polygonalLasso {
                    let docP = CGPoint(x: (value.location.x - imageOrigin.x) / docToView,
                                       y: (value.location.y - imageOrigin.y) / docToView)
                    let now = Date()
                    let recentClick = (lastPolyClickAt.map { now.timeIntervalSince($0) < 0.4 } ?? false)
                    let nearLastClick = (lastPolyClickDoc.map {
                        hypot(docP.x - $0.x, docP.y - $0.y) < 8 / docToView
                    } ?? false)
                    let isDoubleClick = recentClick && nearLastClick
                    let nearStart = (polyLassoVertices.first.map {
                        hypot(docP.x - $0.x, docP.y - $0.y) < 8 / docToView
                    } ?? false)
                    let isClickOnStart = polyLassoVertices.count >= 3 && nearStart

                    if isDoubleClick || isClickOnStart {
                        if polyLassoVertices.count >= 3 {
                            let p = CGMutablePath()
                            p.move(to: polyLassoVertices[0])
                            for v in polyLassoVertices.dropFirst() { p.addLine(to: v) }
                            p.closeSubpath()
                            store.setSelection(path: p)
                        } else {
                            store.clearSelection()
                        }
                        polyLassoVertices = []
                        lastPolyClickAt = nil
                        lastPolyClickDoc = nil
                    } else {
                        polyLassoVertices.append(docP)
                        lastPolyClickAt = now
                        lastPolyClickDoc = docP
                    }
                    return
                }
                if dragStart == nil, let start = missStart {
                    let dx = value.location.x - start.x
                    let dy = value.location.y - start.y
                    if hypot(dx, dy) < 4 {
                        store.activeLayerID = nil
                    }
                }
                dragStart = nil
                missStart = nil
                tatStart = nil
            }
    }

    private func makeStart(kind: DragStart.Kind, smart: SmartSource, at docP: CGPoint) -> DragStart {
        DragStart(
            kind: kind,
            startCenter: CGPoint(x: smart.centerX, y: smart.centerY),
            startScaleX: smart.scaleX,
            startScaleY: smart.scaleY,
            startRotation: smart.rotationDeg,
            startMouseDoc: docP
        )
    }

    private func hitTestTextOrNil(layer: PXLayer, atDoc p: CGPoint) -> DragStart.Kind? {
        guard let b = textBBoxDoc(layer: layer) else { return nil }
        let hitRadius: CGFloat = 10 / docToView
        let corners: [(CGPoint, DragStart.Kind)] = [
            (CGPoint(x: b.minX, y: b.minY), .cornerTL),
            (CGPoint(x: b.maxX, y: b.minY), .cornerTR),
            (CGPoint(x: b.minX, y: b.maxY), .cornerBL),
            (CGPoint(x: b.maxX, y: b.maxY), .cornerBR),
        ]
        for (pt, kind) in corners {
            if hypot(p.x - pt.x, p.y - pt.y) <= hitRadius { return kind }
        }
        if b.insetBy(dx: -hitRadius, dy: -hitRadius).contains(p) { return .move }
        return nil
    }

    private func hitTestOrNil(smart: SmartSource, atDoc p: CGPoint) -> DragStart.Kind? {
        let b = bboxDoc(smart: smart)
        let hitRadius: CGFloat = 10 / docToView
        let corners: [(CGPoint, DragStart.Kind)] = [
            (CGPoint(x: b.minX, y: b.minY), .cornerTL),
            (CGPoint(x: b.maxX, y: b.minY), .cornerTR),
            (CGPoint(x: b.minX, y: b.maxY), .cornerBL),
            (CGPoint(x: b.maxX, y: b.maxY), .cornerBR),
        ]
        for (pt, kind) in corners {
            if hypot(p.x - pt.x, p.y - pt.y) <= hitRadius { return kind }
        }
        if b.insetBy(dx: -hitRadius, dy: -hitRadius).contains(p) { return .move }
        return nil
    }

    // MARK: - HSL Targeted Adjustment Tool

    /// Pencil / Eraser drag handler. On the first call of a stroke we
    /// auto-create a transparent paint layer if the active layer can't be
    /// painted on, take an undo checkpoint, and spin up a `PaintStroke`.
    /// Subsequent calls extend the stroke and live-commit to the layer.
    private func handlePaintDrag(docP: CGPoint, eraser: Bool) {
        if paintStroke == nil {
            let target = paintTargetLayer(eraser: eraser)
            guard let L = target else { return }
            store.checkpoint(eraser ? "Erase" : "Paint")
            paintStroke = PaintStroke(
                layer: L,
                canvasSize: store.canvasSize,
                isEraser: eraser,
                color: store.foreground,
                settings: store.brush,
                selectionPath: store.selectionPath
            )
        }
        guard let stroke = paintStroke else { return }
        stroke.addPoint(docP)
        stroke.commitToLayer()
        store.invalidate()
    }

    /// Magic Wand handler — flood-fill the composite from the click point,
    /// build a CGPath from the resulting mask, set as the document's
    /// selection. Reads `magicWandTolerance` and `magicWandContiguous`
    /// from the store.
    private func handleMagicWand(at docP: CGPoint) {
        guard let cg = LayerRenderer.composite(store: store) else { return }
        guard let mask = SelectionTools.floodFill(
            in: cg,
            seed: docP,
            tolerance: store.magicWandTolerance,
            contiguous: store.magicWandContiguous
        ) else {
            tlog("magicWand: floodFill returned nil")
            return
        }
        guard let path = SelectionTools.maskToPath(mask, canvasSize: store.canvasSize) else {
            tlog("magicWand: maskToPath returned nil")
            return
        }
        store.checkpoint("Magic Wand")
        store.setSelection(path: path)
        store.invalidate()
    }

    /// Smart Select handler — runs Vision foreground-instance segmentation
    /// on the composite, picks the instance under the cursor, converts its
    /// mask to a path. The first selection on a busy photo can take
    /// 100-300ms; subsequent clicks reuse the same Vision request only if
    /// the source hasn't changed (we don't cache yet — fresh request each
    /// click).
    private func handleSmartSelect(at docP: CGPoint) {
        guard let cg = LayerRenderer.composite(store: store) else { return }
        guard let mask = SelectionTools.smartSelectMask(
            in: cg,
            click: docP,
            canvasSize: store.canvasSize
        ) else {
            tlog("smartSelect: no mask produced")
            return
        }
        guard let path = SelectionTools.maskToPath(mask, canvasSize: store.canvasSize) else {
            tlog("smartSelect: maskToPath returned nil")
            return
        }
        store.checkpoint("Smart Select")
        store.setSelection(path: path)
        store.invalidate()
    }

    /// Returns a raster layer suitable for painting/erasing on. If the active
    /// layer is already a flat raster (no smart source, no mask), returns it.
    /// Otherwise, for the pencil, inserts a new transparent paint layer above
    /// the active layer and makes it active. Eraser doesn't auto-create — you
    /// can't erase pixels that aren't there.
    private func paintTargetLayer(eraser: Bool) -> PXLayer? {
        if let A = store.activeLayer, A.kind == .raster, A.smart == nil {
            return A
        }
        if eraser { return nil }
        let new = PXLayer(name: "Paint", kind: .raster)
        store.addLayer(new)
        return new
    }

    /// Hue centers in degrees, in the same fixed band order used by
    /// `HSLAdjustments.asDeltaTable` and the renderer's LUT generator.
    private static let tatHueCenters: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

    private func handleTATDrag(value: DragGesture.Value, docP: CGPoint, channel: HSLTATChannel) {
        guard let layer = store.activeLayer else { return }

        // First call in this drag — sample pixel, compute band weights, snapshot
        // current slider values, take an undo checkpoint.
        if tatStart == nil {
            // Composite the document and sample the pixel under the click. We
            // compose once on click (not per-frame); the band weights stay
            // fixed for the whole drag so the target doesn't chase its tail.
            guard let cg = LayerRenderer.composite(store: store) else { return }
            let px = Int(docP.x.rounded())
            let py = Int(docP.y.rounded())
            guard px >= 0, px < cg.width, py >= 0, py < cg.height else { return }
            guard let (r, g, b) = sampleSRGB(cg: cg, x: px, y: py) else { return }
            let (hueNorm, sat, _) = rgbToHSV(r: r, g: g, b: b)
            // Pure-gray pixels have undefined hue; nothing to target.
            guard sat > 0.05 else {
                store.checkpoint("HSL TAT (no-op)")  // still take a checkpoint so canceling deactivation feels symmetric
                return
            }

            let weights = bandWeights(forHueDeg: hueNorm * 360)
            var startVals: [Int: Double] = [:]
            for (idx, _) in weights {
                startVals[idx] = hslSliderValue(layer.adjust.hsl, bandIdx: idx, channel: channel)
            }
            store.checkpoint("HSL Targeted Adjust")
            tatStart = TATStart(startMouseY: value.location.y,
                                channel: channel,
                                bandWeights: weights,
                                startValues: startVals)
            return
        }

        // Subsequent calls — apply delta. Up = positive (Lightroom muscle
        // memory: drag up to increase, drag down to decrease).
        let dy = tatStart!.startMouseY - value.location.y
        let delta = Double(dy) / 200.0   // 200 px = full ±1 slider
        for (idx, weight) in tatStart!.bandWeights {
            let start = tatStart!.startValues[idx] ?? 0
            let new = max(-1, min(1, start + delta * weight))
            setHSLSliderValue(&layer.adjust.hsl, bandIdx: idx, channel: tatStart!.channel, value: new)
        }
        store.invalidate()
    }

    /// Linear interpolation in hue between adjacent band centers — same
    /// semantics as the renderer's LUT generator. Returns 1-2 entries.
    private func bandWeights(forHueDeg hueDeg: Double) -> [(idx: Int, weight: Double)] {
        let centers = Self.tatHueCenters
        let n = centers.count
        for i in 0..<n {
            let cA = centers[i]
            let cB = centers[(i + 1) % n]
            let span = (cB - cA + 360).truncatingRemainder(dividingBy: 360)
            let dist = (hueDeg - cA + 360).truncatingRemainder(dividingBy: 360)
            if dist < span || (dist == 0 && i == 0) {
                let t = span > 0 ? dist / span : 0
                return [(i, 1 - t), ((i + 1) % n, t)]
            }
        }
        return [(0, 1.0)]
    }

    /// Sample a single sRGB pixel from a CGImage at integer (x, y) — top-left
    /// origin. Decouples us from the source bitmap's color space + byte order
    /// by drawing the 1×1 cropped tile into a known sRGB RGBA8 context.
    private func sampleSRGB(cg: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double)? {
        let crop = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) ?? cg
        var bytes: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBufferPointer { buf -> (Double, Double, Double)? in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Double(buf[0]) / 255, Double(buf[1]) / 255, Double(buf[2]) / 255)
        }
    }

    private func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let v = maxC
        let s = maxC > 0 ? delta / maxC : 0
        var h: Double = 0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, v)
    }

    private func hslSliderValue(_ hsl: HSLAdjustments, bandIdx idx: Int, channel: HSLTATChannel) -> Double {
        let row = hsl.asDeltaTable[idx]
        switch channel {
        case .hue: return row.h
        case .sat: return row.s
        case .lum: return row.l
        }
    }

    private func setHSLSliderValue(_ hsl: inout HSLAdjustments, bandIdx idx: Int, channel: HSLTATChannel, value: Double) {
        // Mirror of asDeltaTable's order: red, orange, yellow, green, aqua,
        // blue, purple, magenta. Branch on channel + idx — verbose but cheap
        // and clearer than building a table of WritableKeyPaths.
        switch (idx, channel) {
        case (0, .hue): hsl.redHue = value
        case (0, .sat): hsl.redSat = value
        case (0, .lum): hsl.redLum = value
        case (1, .hue): hsl.orangeHue = value
        case (1, .sat): hsl.orangeSat = value
        case (1, .lum): hsl.orangeLum = value
        case (2, .hue): hsl.yellowHue = value
        case (2, .sat): hsl.yellowSat = value
        case (2, .lum): hsl.yellowLum = value
        case (3, .hue): hsl.greenHue = value
        case (3, .sat): hsl.greenSat = value
        case (3, .lum): hsl.greenLum = value
        case (4, .hue): hsl.aquaHue = value
        case (4, .sat): hsl.aquaSat = value
        case (4, .lum): hsl.aquaLum = value
        case (5, .hue): hsl.blueHue = value
        case (5, .sat): hsl.blueSat = value
        case (5, .lum): hsl.blueLum = value
        case (6, .hue): hsl.purpleHue = value
        case (6, .sat): hsl.purpleSat = value
        case (6, .lum): hsl.purpleLum = value
        case (7, .hue): hsl.magentaHue = value
        case (7, .sat): hsl.magentaSat = value
        case (7, .lum): hsl.magentaLum = value
        default: break
        }
    }
}

// MARK: - Tool cursor + key bindings

/// Backs an NSTrackingArea on the canvas overlay so the system cursor
/// reflects the active tool — crosshair for selection / paint, I-beam for
/// text, eyedropper for color sampling, etc. The HSL TAT mode wins over
/// any tool-based cursor.
private struct ToolCursorOverlay: NSViewRepresentable {
    let tool: Tool
    let tatActive: Bool

    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ nsView: CursorView, context: Context) {
        nsView.tool = tool
        nsView.tatActive = tatActive
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    /// HSL TAT scope cursor — black glyph + white halo for contrast against
    /// any photo content. Built once, cached.
    fileprivate static let scopeCursor: NSCursor = makeSymbolCursor(name: "scope", hotSpot: NSPoint(x: 14, y: 14))
    fileprivate static let eyedropperCursor: NSCursor = makeSymbolCursor(name: "eyedropper", hotSpot: NSPoint(x: 6, y: 22))

    /// Render a custom cursor from an SF Symbol with a white halo for
    /// contrast on dark images. Used for HSL TAT scope + Eyedropper —
    /// macOS doesn't ship system cursors for either.
    private static func makeSymbolCursor(name: String, hotSpot: NSPoint) -> NSCursor {
        let haloConfig = NSImage.SymbolConfiguration(pointSize: 22, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white]))
        let halo = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(haloConfig)
        let coreConfig = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.black]))
        let core = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(coreConfig)
        let canvas = NSSize(width: 28, height: 28)
        let bitmap = NSImage(size: canvas, flipped: false) { _ in
            if let halo {
                let s = halo.size
                halo.draw(in: NSRect(x: (canvas.width - s.width) / 2,
                                     y: (canvas.height - s.height) / 2,
                                     width: s.width, height: s.height))
            }
            if let core {
                let s = core.size
                core.draw(in: NSRect(x: (canvas.width - s.width) / 2,
                                     y: (canvas.height - s.height) / 2,
                                     width: s.width, height: s.height))
            }
            return true
        }
        return NSCursor(image: bitmap, hotSpot: hotSpot)
    }

    /// Resolve the right NSCursor for a given tool. nil = let the system
    /// pick (default arrow). Pencil/eraser use a plain crosshair as the
    /// system cursor — the brush-radius preview circle is drawn in the
    /// SwiftUI Canvas above, since NSCursor image-scaling can't be made
    /// pixel-exact across the full size range.
    fileprivate static func cursor(for tool: Tool) -> NSCursor? {
        switch tool {
        case .move:                                       return nil
        case .marquee, .lasso, .polygonalLasso,
             .magicWand, .smartSelect,
             .relight, .pen, .pencil, .eraser:            return .crosshair
        case .text:                                       return .iBeam
        case .eyedropper:                                 return eyedropperCursor
        }
    }

    final class CursorView: NSView {
        var tool: Tool = .move {
            didSet {
                if tool != oldValue {
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                    pushIfHovered()
                }
            }
        }
        var tatActive: Bool = false {
            didSet {
                if tatActive != oldValue {
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                    pushIfHovered()
                }
            }
        }

        /// Fire `NSCursor.set()` synchronously if the system cursor is
        /// currently inside this view. No-op otherwise so we don't fight
        /// other windows' cursor management.
        private func pushIfHovered() {
            guard let win = window else { return }
            let mouseInWin = win.mouseLocationOutsideOfEventStream
            let mouseInView = convert(mouseInWin, from: nil)
            if bounds.contains(mouseInView) {
                resolvedCursor?.set()
            }
        }
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let opts: NSTrackingArea.Options = [.activeInKeyWindow,
                                                .mouseEnteredAndExited,
                                                .mouseMoved,
                                                .cursorUpdate,
                                                .inVisibleRect]
            let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        private var resolvedCursor: NSCursor? {
            if tatActive { return ToolCursorOverlay.scopeCursor }
            return ToolCursorOverlay.cursor(for: tool)
        }

        override func cursorUpdate(with event: NSEvent) {
            if let c = resolvedCursor { c.set() } else { super.cursorUpdate(with: event) }
        }

        override func mouseMoved(with event: NSEvent) {
            resolvedCursor?.set()
        }

        // Don't intercept clicks — the gesture handler above us must still get them.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// AppKit-backed mouse-position tracker. Reports the pointer's location
/// inside the host view (in SwiftUI view coords, top-down y) on every
/// movement, and reports `nil` when the pointer leaves. SwiftUI doesn't
/// expose continuous in-view tracking without committing to a hover
/// ScrollView/onContinuousHover, both of which have edge cases here. This
/// is the simplest way to drive a brush-radius preview circle that
/// follows the cursor in the SwiftUI Canvas.
private struct MouseTracker: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> Tracker {
        let v = Tracker()
        v.onMove = onMove
        return v
    }

    func updateNSView(_ nsView: Tracker, context: Context) {
        nsView.onMove = onMove
    }

    final class Tracker: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var eventMonitor: Any?

        override var isFlipped: Bool { true }   // top-down y for SwiftUI parity

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let opts: NSTrackingArea.Options = [.activeInKeyWindow,
                                                .mouseEnteredAndExited,
                                                .mouseMoved,
                                                .inVisibleRect]
            let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Tear down the previous monitor before creating a new one — the
            // view may move between windows over its lifetime.
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
            guard window != nil else { return }
            // Local monitor catches both mouseMoved AND leftMouseDragged
            // regardless of which view is firstResponder. Tracking-area
            // mouseDragged callbacks don't fire on a hitTest:nil view because
            // it never claims the mouse-down — but local monitors see every
            // in-window event, so the brush ring keeps following the cursor
            // during paint strokes.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
                self?.publish(event)
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let m = eventMonitor {
                NSEvent.removeMonitor(m)
                eventMonitor = nil
            }
        }

        override func mouseEntered(with event: NSEvent) { publish(event) }
        override func mouseMoved(with event: NSEvent)   { publish(event) }
        override func mouseExited(with event: NSEvent)  { onMove?(nil) }

        private func publish(_ event: NSEvent) {
            // Only report when the cursor is actually inside our bounds.
            // Otherwise dragging anywhere else in the window would jiggle
            // the brush ring at coordinates outside the canvas.
            let p = convert(event.locationInWindow, from: nil)
            if bounds.contains(p) {
                onMove?(p)
            }
        }

        // Don't intercept clicks — gesture handlers above us must still get them.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Installs a local NSEvent monitor that consumes the Escape key while
/// active. Used to dismiss HSL TAT mode without forcing the user back to
/// the inspector to click the scope button.
private struct TATKeyHandler: NSViewRepresentable {
    let active: Bool
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(active: active, onEscape: onEscape)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var onEscape: () -> Void = {}

        func update(active: Bool, onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if event.keyCode == 53 {  // Escape
                        self.onEscape()
                        return nil
                    }
                    return event
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
