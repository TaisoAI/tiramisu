import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CanvasView: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        GeometryReader { proxy in
            let fit = min(proxy.size.width / store.canvasSize.width,
                          proxy.size.height / store.canvasSize.height)
            let scale = max(0.05, min(8, fit * store.viewportZoom))
            let dw = store.canvasSize.width * scale
            let dh = store.canvasSize.height * scale

            ZStack {
                Canvas { ctx, size in
                    let sq: CGFloat = 14
                    let cols = Int(size.width / sq) + 1
                    let rows = Int(size.height / sq) + 1
                    for r in 0..<rows {
                        for c in 0..<cols {
                            let on = (r + c) % 2 == 0
                            let rect = CGRect(x: CGFloat(c) * sq, y: CGFloat(r) * sq, width: sq, height: sq)
                            ctx.fill(Path(rect), with: .color(on ? Color(white: 0.10) : Color(white: 0.13)))
                        }
                    }
                }

                CompositeImageView()
                    .frame(width: dw, height: dh)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    .overlay(alignment: .topLeading) {
                        GuidesOverlay()
                            .frame(width: dw, height: dh)
                            .allowsHitTesting(false)
                    }
                    .offset(x: store.viewportPan.width, y: store.viewportPan.height)
                    .onTapGesture(count: 2) {
                        if let layer = store.activeLayer, layer.smart != nil {
                            store.openSmartLayerInExternalEditor(layer)
                        }
                    }

                // Transform handles fill the entire stage, so they never clip at the
                // canvas edge regardless of scale or position. The overlay needs to
                // know where the image sits inside the stage — and that origin
                // shifts with the viewport pan so handles track the panned image.
                TransformOverlay(
                    docToView: scale,
                    imageOrigin: CGPoint(
                        x: (proxy.size.width - dw) / 2 + store.viewportPan.width,
                        y: (proxy.size.height - dh) / 2 + store.viewportPan.height
                    )
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Two-finger trackpad pan — caught by the NSView at the back of
            // the ZStack. SwiftUI gestures don't see scroll-wheel events, so
            // we go through AppKit for this one.
            .background(CanvasScrollCatcher { dx, dy in
                store.viewportPan.width  += dx
                store.viewportPan.height += dy
            })
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        store.viewportZoom = clampZoom(store.viewportZoomBase * value.magnification)
                    }
                    .onEnded { _ in
                        store.viewportZoomBase = store.viewportZoom
                    }
            )
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .overlay(alignment: .bottomLeading) {
                ZoomHUD().padding(12)
            }
        }
    }

    private func clampZoom(_ v: Double) -> Double { max(0.05, min(8, v)) }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        tlog("drop with \(providers.count) provider(s)")
        for provider in providers {
            let types = provider.registeredTypeIdentifiers
            tlog(" provider types: \(types)")

            // Prefer raw image bytes — works regardless of sandbox and
            // doesn't rely on post-callback file access.
            let imageTypeIDs = [UTType.png.identifier, UTType.jpeg.identifier,
                                UTType.webP.identifier, UTType.heic.identifier, UTType.tiff.identifier,
                                UTType.gif.identifier, UTType.bmp.identifier, UTType.image.identifier]
            if let id = imageTypeIDs.first(where: provider.hasItemConformingToTypeIdentifier) {
                tlog("  loading as image type: \(id)")
                _ = provider.loadDataRepresentation(forTypeIdentifier: id) { data, err in
                    if let err { tlog("  image data load error: \(err)") }
                    guard let data, !data.isEmpty else {
                        tlog("  image data was empty for \(id)")
                        return
                    }
                    tlog("  got \(data.count) bytes for \(id)")
                    Task { @MainActor in
                        let ext = UTType(id)?.preferredFilenameExtension ?? "png"
                        if let L = store.placeSmartImage(data: data, format: ext) {
                            tlog("  placed smart layer: \(L.name)")
                        } else {
                            tlog("  placeSmartImage(data:) returned nil — decode failed")
                        }
                    }
                }
                return true
            }

            // Fall back to a file representation (gives us temporary sandbox access).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                tlog("  loading via fileRepresentation")
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, err in
                    if let err { tlog("  fileRepresentation error: \(err)") }
                    guard let url else { return }
                    tlog("  got file URL: \(url.path)")
                    // COPY the bytes now while we still have read access. The URL is
                    // valid only for the duration of this callback.
                    let data = try? Data(contentsOf: url)
                    let ext = url.pathExtension.lowercased()
                    if let data, !data.isEmpty {
                        tlog("  read \(data.count) bytes from file")
                        Task { @MainActor in
                            if let L = store.placeSmartImage(data: data, format: ext) {
                                L.name = url.deletingPathExtension().lastPathComponent
                                tlog("  placed smart layer: \(L.name)")
                            } else {
                                tlog("  decode failed for \(url.lastPathComponent)")
                            }
                        }
                    } else {
                        tlog("  could not read bytes from \(url.path) — sandbox blocked")
                    }
                }
                return true
            }
        }
        return false
    }
}

private struct ZoomHUD: View {
    @Environment(DocumentStore.self) private var store
    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.viewportZoom = max(0.05, store.viewportZoom / 1.25)
                store.viewportZoomBase = store.viewportZoom
            } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(store.viewportZoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button {
                store.viewportZoom = min(8, store.viewportZoom * 1.25)
                store.viewportZoomBase = store.viewportZoom
            } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Fit") {
                store.viewportZoom = 1; store.viewportZoomBase = 1
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .glassEffect(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CompositeImageView: NSViewRepresentable {
    @Environment(DocumentStore.self) private var store

    func makeNSView(context: Context) -> CanvasNSView {
        let v = CanvasNSView()
        v.store = store
        return v
    }
    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        nsView.store = store
        nsView.tick = store.renderTick
        nsView.needsDisplay = true
    }
}

final class CanvasNSView: NSView {
    weak var store: DocumentStore?
    var tick: Int = -1
    private var cached: CGImage?
    private var cachedTick: Int = -2

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let store else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        if cachedTick != tick {
            cached = MainActor.assumeIsolated { LayerRenderer.composite(store: store) }
            cachedTick = tick
        }
        if let img = cached {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: bounds)
        }
    }
}

private struct SafeAreaGuides: View {
    var body: some View {
        Canvas { ctx, size in
            let bottomRight = CGRect(x: size.width - size.width * 0.18,
                                     y: size.height - size.height * 0.12,
                                     width: size.width * 0.16,
                                     height: size.height * 0.09)
            ctx.stroke(Path(roundedRect: bottomRight, cornerRadius: 4),
                       with: .color(.yellow.opacity(0.35)), lineWidth: 1)
        }
    }
}
