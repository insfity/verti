import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum StudioError: LocalizedError {
    case invalidImage(String), incomplete, encodeFailed, missingGainMap, badDimensions
    public var errorDescription: String? {
        switch self {
        case .invalidImage(let name): return "无法读取 \(name)。请选择有效的 JPEG 或 HEIC 照片。"
        case .incomplete: return "请先填满所有图片区块。"
        case .encodeFailed: return "图像编码失败，未写入导出文件。"
        case .missingGainMap: return "系统未能生成有效的 HDR gain map，已取消导出。"
        case .badDimensions: return "导出尺寸无效。"
        }
    }
}

// CIImage is immutable; imported image bytes remain owned by its graph.
public struct Photo: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let name: String
    public let sdr: CIImage
    public let hdr: CIImage?
    public let hasGainMap: Bool
    public var size: CGSize { sdr.extent.size }
    public init(name: String, sdr: CIImage, hdr: CIImage? = nil, hasGainMap: Bool = false) {
        self.name = name; self.sdr = sdr; self.hdr = hdr; self.hasGainMap = hasGainMap
    }
    public static func containsGainMap(_ source: CGImageSource) -> Bool {
        [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
        }
    }
    public static func load(url: URL) throws -> Photo {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Retain the encoded bytes in CIImage: no dependency on the source file after import.
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type as String),
              let base = CIImage(data: data, options: [.applyOrientationProperty: true, .expandToHDR: false, .toneMapHDRtoSDR: true]),
              base.extent.width > 0, base.extent.height > 0 else { throw StudioError.invalidImage(url.lastPathComponent) }
        let hasMap = containsGainMap(source)
        let expanded = hasMap ? CIImage(data: data, options: [.applyOrientationProperty: true, .expandToHDR: true]) : nil
        if hasMap && expanded == nil { throw StudioError.invalidImage(url.lastPathComponent) }
        return Photo(name: url.lastPathComponent, sdr: normalized(base), hdr: expanded.map(normalized), hasGainMap: hasMap)
    }
    private static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}

public struct Placement: Equatable, Sendable {
    public var zoom: Double = 1
    /// Displacement in fractions of the block's width/height; positive y is down.
    public var x: Double = 0
    public var y: Double = 0
    public init(zoom: Double = 1, x: Double = 0, y: Double = 0) { self.zoom = zoom; self.x = x; self.y = y }
}
public struct Slot: Identifiable, Sendable {
    public let id = UUID()
    public var photo: Photo?
    public var placement = Placement()
    public init(photo: Photo? = nil) { self.photo = photo }
}
public enum PortraitRatio: String, CaseIterable, Identifiable, Sendable {
    case story = "9:16", social = "3:4", classic = "2:3", feed = "4:5", cinema = "9:21"
    public var id: String { rawValue }
    public var value: Double {
        switch self { case .story: return 9/16; case .social: return 3/4; case .classic: return 2/3; case .feed: return 4/5; case .cinema: return 9/21 }
    }
    public var subtitle: String {
        switch self { case .story: return "故事 / 壁纸"; case .social: return "社交分享"; case .classic: return "经典竖幅"; case .feed: return "信息流"; case .cinema: return "超长竖幅" }
    }
}
public struct FrameColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public static let paper = FrameColor(0.97, 0.955, 0.925)
    public var ciColor: CIColor { CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)! }
}
public struct CompositionSettings: Sendable {
    public var ratio: PortraitRatio = .story
    public var count = 3
    public var longEdge = 3840
    public var border: Double = 0.035
    public var gap: Double = 0.018
    public var color = FrameColor.paper
    public var shadow = false
    public var shadowOpacity: Double = 0.28
    public var shadowBlur: Double = 0.018
    public var shadowOffset: Double = 0.010
    public var hdrEnabled = true
    public var format: ExportFormat = .heic
    public var quality: Double = 0.95
    public init() {}
    public var size: CGSize { CGSize(width: (Double(longEdge) * ratio.value).rounded(), height: Double(longEdge)) }
    public var hasFrame: Bool { border > 0 || gap > 0 }
}
public enum ExportFormat: String, CaseIterable, Sendable { case heic = "HEIC", jpeg = "JPEG"
    public var ext: String { self == .heic ? "heic" : "jpg" }
}
public struct Composition: Sendable {
    public var slots: [Slot]
    public var settings: CompositionSettings
    public init(slots: [Slot], settings: CompositionSettings) { self.slots = slots; self.settings = settings }
    public var isComplete: Bool { slots.count == settings.count && slots.allSatisfy { $0.photo != nil } }
    public var isHDR: Bool {
        let photos = slots.compactMap(\.photo)
        return settings.hdrEnabled && !photos.isEmpty && photos.allSatisfy { $0.hasGainMap && $0.hdr != nil }
    }
    public var exportFormat: ExportFormat { isHDR ? settings.format : .jpeg }
    public func blocks() -> [CGRect] {
        let size = settings.size
        let margin = (size.width * settings.border).rounded()
        let gap = (size.width * settings.gap).rounded()
        let usable = size.height - 2 * margin - gap * Double(settings.count - 1)
        // Round the boundaries independently, so seamless layouts never expose a subpixel seam.
        return (0..<settings.count).map { index in
            let top = margin + (usable * Double(index) / Double(settings.count)).rounded() + gap * Double(index)
            let bottom = margin + (usable * Double(index + 1) / Double(settings.count)).rounded() + gap * Double(index)
            return CGRect(x: margin, y: size.height - bottom, width: size.width - 2 * margin, height: bottom - top)
        }
    }
    public static func imageRect(size: CGSize, block: CGRect, placement p: Placement) -> CGRect {
        let scale = max(block.width / size.width, block.height / size.height) * p.zoom
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: block.midX - w / 2 + p.x * block.width,
                      y: block.midY - h / 2 - p.y * block.height, width: w, height: h)
    }
    public func fittedPlacement(index: Int) -> Placement {
        guard let photo = slots[index].photo else { return Placement() }
        let block = blocks()[index]
        let fill = max(block.width / photo.size.width, block.height / photo.size.height)
        let fit = min(block.width / photo.size.width, block.height / photo.size.height)
        return Placement(zoom: fit / fill)
    }
    public func minimumZoom(index: Int) -> Double {
        min(0.05, fittedPlacement(index: index).zoom * 0.5)
    }
    public func clamped(_ p: Placement, index: Int) -> Placement {
        guard let photo = slots[index].photo else { return p }
        let block = blocks()[index]
        var p = p; p.zoom = min(6, max(minimumZoom(index: index), p.zoom))
        let rect = Self.imageRect(size: photo.size, block: block, placement: p)
        let mx = max(0, (rect.width + block.width) / 2 - min(rect.width, block.width) * 0.05) / block.width
        let my = max(0, (rect.height + block.height) / 2 - min(rect.height, block.height) * 0.05) / block.height
        p.x = min(mx, max(-mx, p.x)); p.y = min(my, max(-my, p.y))
        return p
    }
}

// CIContext and CIImage are immutable/thread-safe; no mutable filter instances are shared.
public final class Compositor: @unchecked Sendable {
    public let context: CIContext
    public static let displaySpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    public static let exportSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    public init() {
        context = CIContext(options: [.workingColorSpace: Self.displaySpace, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    }
    public func image(_ composition: Composition, hdr: Bool) -> CIImage {
        let s = composition.settings
        let canvas = CGRect(origin: .zero, size: s.size)
        var result = CIImage(color: s.color.ciColor).cropped(to: canvas)
        let blocks = composition.blocks()
        var images: [CIImage] = []
        var shadows: [CIImage] = []
        for (i, slot) in composition.slots.enumerated() {
            let block = blocks[i]
            guard let photo = slot.photo else {
                images.append(CIImage(color: CIColor(red: 0.89, green: 0.88, blue: 0.86)).cropped(to: block)); continue
            }
            let source = hdr ? (photo.hdr ?? photo.sdr) : photo.sdr
            let rect = Composition.imageRect(size: photo.size, block: block, placement: slot.placement)
            let scale = rect.width / source.extent.width
            let placed = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)).cropped(to: block)
            images.append(placed)
            if s.hasFrame && s.shadow {
                let visible = rect.intersection(block)
                if !visible.isNull {
                    let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: s.shadowOpacity))
                        .cropped(to: visible)
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: s.size.width * s.shadowBlur])
                        .transformed(by: CGAffineTransform(translationX: 0, y: -s.size.width * s.shadowOffset))
                    shadows.append(shadow)
                }
            }
        }
        for shadow in shadows { result = shadow.composited(over: result) }
        for photo in images { result = photo.composited(over: result) }
        return result.cropped(to: canvas)
    }
    public func preview(_ composition: Composition, maxEdge: CGFloat = 1600) -> CGImage? {
        var image = image(composition, hdr: composition.isHDR)
        let scale = min(1, maxEdge / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if composition.isHDR {
            // AppKit needs an explicitly HDR-tagged display image. Extended linear
            // working pixels alone can be composited as SDR and clip at white.
            let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var peak = [Float](repeating: 0, count: 4)
            context.render(maximum, toBitmap: &peak, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: Self.displaySpace)
            let headroom = max(1, peak[0], peak[1], peak[2])
            guard let pq = context.createCGImage(image, from: image.extent, format: .RGBAh,
                      colorSpace: CGColorSpace(name: CGColorSpace.displayP3_PQ)!) else { return nil }
            return CGImageCreateCopyWithContentHeadroom(headroom, pq)
        }
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.exportSpace)
    }
    public func encoded(_ composition: Composition) throws -> Data {
        guard composition.isComplete else { throw StudioError.incomplete }
        guard (640...8192).contains(composition.settings.longEdge) else { throw StudioError.badDimensions }
        let base = image(composition, hdr: false)
        var options: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): composition.settings.quality]
        if composition.isHDR { options[.hdrImage] = image(composition, hdr: true) }
        let data: Data?
        switch composition.exportFormat {
        case .heic: data = context.heifRepresentation(of: base, format: .RGBA8, colorSpace: Self.exportSpace, options: options)
        case .jpeg: data = context.jpegRepresentation(of: base, colorSpace: Self.exportSpace, options: options)
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw StudioError.encodeFailed }
        if composition.isHDR && !Photo.containsGainMap(source) { throw StudioError.missingGainMap }
        if !composition.isHDR && Photo.containsGainMap(source) { throw StudioError.encodeFailed }
        return data
    }
    public func export(_ composition: Composition, to url: URL) throws {
        let data = try encoded(composition)
        try data.write(to: url, options: .atomic)
    }
}
