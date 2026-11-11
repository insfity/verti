import SwiftUI
import AppKit
import VerticalCore

struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> InteractiveCanvas { InteractiveCanvas(model: model) }
    func updateNSView(_ view: InteractiveCanvas, context: Context) {
        view.model = model
        if view.currentImage !== model.preview {
            view.currentImage = model.preview
            if let cg = model.preview { view.imageView.image = NSImage(cgImage: cg, size: model.settings.size) }
            else { view.imageView.image = nil }
        }
        view.imageView.preferredImageDynamicRange = model.composition.isHDR ? .high : .standard
        view.needsLayout = true; view.overlay.needsDisplay = true
    }
}
final class CanvasOverlay: NSView {
    weak var canvas: InteractiveCanvas?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { canvas?.drawOverlay() }
}
final class PassthroughImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
final class InteractiveCanvas: NSView {
    var model: EditorModel
    let imageView = PassthroughImage()
    let overlay = CanvasOverlay()
    var currentImage: CGImage?
    var pageRect: CGRect = .zero
    var dragStart: CGPoint?
    var originalPlacement = Placement()
    var dragIndex: Int?
    var pendingPlacement: Placement?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: EditorModel) {
        self.model = model; super.init(frame: .zero)
        wantsLayer = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        addSubview(imageView); overlay.canvas = self; addSubview(overlay)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("拼图画布：单击选择照片，拖动调整位置，滚轮或双指捏合缩放")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let available = bounds.insetBy(dx: 40, dy: 10)
        let size = model.settings.size
        let scale = max(0.01, min(available.width / size.width, available.height / size.height))
        pageRect = CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
        imageView.frame = pageRect; overlay.frame = bounds; overlay.needsDisplay = true
    }
    func screenBlocks() -> [CGRect] {
        let scale = pageRect.width / model.settings.size.width
        return model.composition.blocks().map { block in
            CGRect(x: pageRect.minX + block.minX * scale,
                   y: pageRect.minY + (model.settings.size.height - block.maxY) * scale,
                   width: block.width * scale, height: block.height * scale)
        }
    }
    func drawOverlay() {
        guard model.hasSelection else { return }
        let blocks = screenBlocks()
        for (index, rect) in blocks.enumerated() {
            if model.slots[index].photo == nil {
                let title = "＋  添加第 \(index + 1) 张照片"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
                let size = title.size(withAttributes: attrs)
                title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            }
            if index == model.selected {
                NSColor(calibratedRed: 0.82, green: 0.35, blue: 0.20, alpha: 1).setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1)); path.lineWidth = 2; path.stroke()
                let badge = CGRect(x: rect.minX + 8, y: rect.minY + 8, width: 24, height: 24)
                NSColor(calibratedRed: 0.82, green: 0.35, blue: 0.20, alpha: 1).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
                "\(index + 1)".draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            }
        }
        drawPhotoBounds()
        for (index, rect) in blocks.enumerated() {
            guard let photo = model.slots[index].photo else { continue }
            let placement = dragIndex == index ? (pendingPlacement ?? model.slots[index].placement) : model.slots[index].placement
            let block = model.composition.blocks()[index]
            let full = Composition.imageRect(size: photo.size, block: block, placement: placement)
            // A tiny numeric tolerance avoids warnings from floating-point rounding.
            if !full.insetBy(dx: -0.01, dy: -0.01).contains(block) {
                let label = "未填满"
                label.draw(at: CGPoint(x: pageRect.maxX + 7, y: rect.midY - 6),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                     .foregroundColor: NSColor(calibratedRed: 0.72, green: 0.30, blue: 0.16, alpha: 1)])
            }
        }
    }
    // The solid frame is the crop; the dashed frame is the uncropped photo.
    // Keep this overlay outside the image view so adjacent blocks never hide it.
    func drawPhotoBounds() {
        let index = dragIndex ?? model.selected
        guard model.slots.indices.contains(index), let photo = model.slots[index].photo else { return }
        let placement = pendingPlacement ?? model.slots[index].placement
        let block = model.composition.blocks()[index]
        let full = Composition.imageRect(size: photo.size, block: block, placement: placement)
        let scale = pageRect.width / model.settings.size.width
        let rect = CGRect(x: pageRect.minX + full.minX * scale,
                          y: pageRect.minY + (model.settings.size.height - full.maxY) * scale,
                          width: full.width * scale, height: full.height * scale)
        strokePhotoBounds(rect)
        // A miniature extent guide remains useful when the photo exceeds the viewport.
        if !bounds.insetBy(dx: 8, dy: 8).contains(rect) {
            let crop = screenBlocks()[index]
            let union = rect.union(crop)
            let panel = CGRect(x: 12, y: bounds.height - 124, width: 150, height: 112)
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
            let factor = min(126 / union.width, 76 / union.height)
            let origin = CGPoint(x: panel.midX - union.width * factor / 2, y: panel.minY + 12)
            func map(_ r: CGRect) -> CGRect {
                CGRect(x: origin.x + (r.minX - union.minX) * factor,
                       y: origin.y + (r.minY - union.minY) * factor,
                       width: r.width * factor, height: r.height * factor)
            }
            NSColor.systemOrange.withAlphaComponent(0.20).setFill()
            NSBezierPath(rect: map(crop)).fill()
            NSColor.systemOrange.setStroke()
            NSBezierPath(rect: map(crop)).stroke()
            strokePhotoBounds(map(rect))
            "完整照片 / 可见区块".draw(at: CGPoint(x: panel.minX + 13, y: panel.maxY - 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
    func strokePhotoBounds(_ rect: CGRect) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3
        NSColor.white.withAlphaComponent(0.95).setStroke(); path.stroke()
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.32, alpha: 1).setStroke(); path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard !model.busy else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let index = screenBlocks().firstIndex(where: { $0.contains(point) }) else {
            model.deselect(); overlay.needsDisplay = true; return
        }
        if let photo = model.slots[index].photo {
            let block = model.composition.blocks()[index]
            let full = Composition.imageRect(size: photo.size, block: block, placement: model.slots[index].placement)
            let scale = pageRect.width / model.settings.size.width
            let sourcePoint = CGPoint(x: (point.x - pageRect.minX) / scale,
                                      y: model.settings.size.height - (point.y - pageRect.minY) / scale)
            if !full.contains(sourcePoint) {
                model.deselect(); overlay.needsDisplay = true; return
            }
        }
        model.selected = index
        if model.slots[index].photo == nil { model.choosePhotos(replace: index); return }
        if event.clickCount == 2 { model.fill(); return }
        dragStart = point; originalPlacement = model.slots[index].placement; dragIndex = index
        pendingPlacement = originalPlacement
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let index = dragIndex, !model.busy else { return }
        let point = convert(event.locationInWindow, from: nil), rect = screenBlocks()[index]
        var p = originalPlacement
        p.x += (point.x - start.x) / rect.width; p.y += (point.y - start.y) / rect.height
        pendingPlacement = model.composition.clamped(p, index: index)
        overlay.needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        let index = dragIndex, placement = pendingPlacement
        dragStart = nil; dragIndex = nil; pendingPlacement = nil
        if let index, let placement, placement != originalPlacement, !model.busy {
            model.place(placement, at: index)
        }
        overlay.needsDisplay = true
    }
    func zoom(at point: CGPoint, multiplier: Double) {
        guard dragStart == nil, !model.busy, let index = screenBlocks().firstIndex(where: { $0.contains(point) }), model.slots[index].photo != nil else { return }
        model.selected = index
        let rect = screenBlocks()[index]
        var p = model.slots[index].placement
        let next = min(6, max(model.composition.minimumZoom(index: index), p.zoom * multiplier)), ratio = next / p.zoom
        // Preserve the source pixel under the pointer while zooming.
        let px = (point.x - rect.midX) / rect.width, py = (point.y - rect.midY) / rect.height
        p.x = px - (px - p.x) * ratio; p.y = py - (py - p.y) * ratio; p.zoom = next
        model.place(p, at: index)
    }
    override func scrollWheel(with event: NSEvent) {
        zoom(at: convert(event.locationInWindow, from: nil), multiplier: exp(-event.scrollingDeltaY * 0.008))
    }
    override func magnify(with event: NSEvent) {
        zoom(at: convert(event.locationInWindow, from: nil), multiplier: max(0.1, 1 + event.magnification))
    }
    override func keyDown(with event: NSEvent) {
        if dragStart != nil {
            if event.keyCode == 53 {
                NSCursor.pop(); dragStart = nil; dragIndex = nil; pendingPlacement = nil
                overlay.needsDisplay = true
            }
            return
        }
        guard !model.busy, model.hasSelection else { return }
        var p = model.slots[model.selected].placement
        let step = event.modifierFlags.contains(.shift) ? 0.05 : 0.005
        switch event.keyCode {
        case 123: p.x -= step
        case 124: p.x += step
        case 125: p.y += step
        case 126: p.y -= step
        default: super.keyDown(with: event); return
        }
        model.place(p, at: model.selected)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { model.busy ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !model.busy, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let target = urls.count == 1 ? screenBlocks().firstIndex(where: { $0.contains(point) }) : nil
        model.importPhotos(urls, replace: target); return true
    }
}
