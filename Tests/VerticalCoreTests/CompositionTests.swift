import Foundation
import CoreImage
import ImageIO
import VerticalCore

final class CompositionTests {
    let renderer = Compositor()
    func photo(hdr: Bool, width: Int = 600, height: Int = 400) -> Photo {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let base = CIImage(color: CIColor(red: 0.8, green: 0.6, blue: 0.3)).cropped(to: rect)
        let expanded = base.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2.0])
        return Photo(name: "fixture", sdr: base, hdr: hdr ? expanded : nil, hasGainMap: hdr)
    }
    func composition(hdr: Bool, format: ExportFormat = .jpeg) -> Composition {
        var settings = CompositionSettings(); settings.count = 2; settings.longEdge = 800; settings.format = format
        return Composition(slots: [Slot(photo: photo(hdr: hdr)), Slot(photo: photo(hdr: hdr, width: 300, height: 700))], settings: settings)
    }
    func testSeamlessGeometryAcrossEveryLayout() {
        for ratio in PortraitRatio.allCases {
            for count in 2...4 {
                var settings = CompositionSettings(); settings.ratio = ratio; settings.count = count; settings.border = 0; settings.gap = 0
                let scene = Composition(slots: (0..<count).map { _ in Slot(photo: photo(hdr: false)) }, settings: settings)
                let blocks = scene.blocks()
                expectEqual(blocks.first!.maxY, settings.size.height)
                expectEqual(blocks.last!.minY, 0)
                expectEqual(blocks.reduce(0) { $0 + $1.height }, settings.size.height)
                for i in 1..<count { expectEqual(blocks[i-1].minY, blocks[i].maxY) }
            }
        }
    }
    func testFitAndDragForAnyAspect() {
        var scene = composition(hdr: false)
        scene.slots += [Slot(photo: photo(hdr: false, width: 20000, height: 100))]
        scene.settings.count = 3
        for i in scene.slots.indices {
            let block = scene.blocks()[i]
            let fit = scene.fittedPlacement(index: i)
            expectEqual(scene.clamped(fit, index: i).zoom, fit.zoom)
            let rect = Composition.imageRect(size: scene.slots[i].photo!.size, block: block, placement: fit)
            expectAtMost(rect.width, block.width + 0.001)
            expectAtMost(rect.height, block.height + 0.001)
            let drag = scene.clamped(Placement(zoom: 0.2, x: 100, y: -100), index: i)
            let moved = Composition.imageRect(size: scene.slots[i].photo!.size, block: block, placement: drag)
            expectTrue(moved.intersects(block), "An image must remain recoverable after dragging")
        }
    }
    func testHDRGatingAndSDRExport() throws {
        var scene = composition(hdr: true)
        expectTrue(scene.isHDR)
        scene.slots[1] = Slot(photo: photo(hdr: false))
        expectFalse(scene.isHDR)
        scene.settings.format = .heic
        expectEqual(scene.exportFormat, .jpeg)
        let data = try renderer.encoded(scene)
        let source = try unwrap(CGImageSourceCreateWithData(data as CFData, nil))
        expectEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        expectFalse(Photo.containsGainMap(source))
        scene.slots[1] = Slot(photo: photo(hdr: true)); scene.settings.hdrEnabled = false
        expectFalse(scene.isHDR)
        let disabled = try renderer.encoded(scene)
        expectFalse(Photo.containsGainMap(CGImageSourceCreateWithData(disabled as CFData, nil)!))
    }
    func testActualHDRGainMapRoundTripBothFormats() throws {
        for format in ExportFormat.allCases {
            var scene = composition(hdr: true, format: format)
            scene.settings.shadow = true; scene.settings.border = 0.08
            scene.slots[1].placement = Placement(zoom: 0.75, x: 0.12, y: -0.1)
            let preview = try unwrap(renderer.preview(scene))
            expectGreater(preview.contentHeadroom, 1)
            expectEqual(preview.colorSpace?.name, CGColorSpace.displayP3_PQ)
            let data = try renderer.encoded(scene)
            let source = try unwrap(CGImageSourceCreateWithData(data as CFData, nil))
            expectTrue(Photo.containsGainMap(source), "\(format) must contain an auxiliary gain map")
            let expanded = try unwrap(CIImage(data: data, options: [.expandToHDR: true]))
            let base = try unwrap(CIImage(data: data, options: [.expandToHDR: false]))
            expectEqual(expanded.extent.size, scene.settings.size)
            let point = scene.blocks()[0]
            let hdrPixel = pixel(expanded, x: Int(point.midX), y: Int(point.midY))
            let sdrPixel = pixel(base, x: Int(point.midX), y: Int(point.midY))
            expectGreater(hdrPixel[0], 1.2, "\(format) must reconstruct HDR light, not merely carry metadata")
            expectGreater(hdrPixel[0], sdrPixel[0] * 2)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("roundtrip.\(format.ext)")
            try data.write(to: url)
            let loaded = try Photo.load(url: url)
            expectTrue(loaded.hasGainMap); expectNotNil(loaded.hdr)
            // Imported images own their bytes and survive source removal.
            try FileManager.default.removeItem(at: url)
            expectGreater(pixel(loaded.hdr!, x: Int(point.midX), y: Int(point.midY))[0], 1.2)
        }
    }
    func testFrameShadowAndCropAreInRenderedPixels() {
        var scene = composition(hdr: false)
        scene.settings.color = FrameColor(1, 1, 1); scene.settings.border = 0.12; scene.settings.gap = 0.08
        let plain = renderer.image(scene, hdr: false)
        scene.settings.shadow = true
        let shadowed = renderer.image(scene, hdr: false)
        let block = scene.blocks()[0]
        let x = Int(block.midX), y = Int(block.minY - 6)
        expectLess(pixel(shadowed, x: x, y: y)[0], pixel(plain, x: x, y: y)[0])
        scene.slots[0].placement = Placement(zoom: 0.2)
        let reduced = renderer.image(scene, hdr: false)
        expectGreater(pixel(reduced, x: Int(block.minX + 10), y: Int(block.midY))[0], 0.95)
    }
    func testPreviewAndExportShareGeometry() throws {
        var scene = composition(hdr: false)
        scene.slots[0].placement = Placement(zoom: 1.7, x: 0.13, y: -0.2)
        scene.settings.shadow = true
        let preview = try unwrap(renderer.preview(scene, maxEdge: 800))
        let data = try renderer.encoded(scene)
        let exported = try unwrap(CIImage(data: data))
        expectEqual(preview.width, Int(scene.settings.size.width))
        expectEqual(preview.height, Int(scene.settings.size.height))
        for rect in scene.blocks() {
            let p = pixel(CIImage(cgImage: preview), x: Int(rect.midX), y: Int(rect.midY))
            let e = pixel(exported, x: Int(rect.midX), y: Int(rect.midY))
            for channel in 0..<3 { expectEqual(p[channel], e[channel], accuracy: 0.025) }
        }
    }
    func testIncompleteExportRejected() {
        var scene = composition(hdr: false); scene.slots[1].photo = nil
        expectThrows(try renderer.encoded(scene))
    }
    func pixel(_ image: CIImage, x: Int, y: Int) -> [Float] {
        var rgba = [Float](repeating: 0, count: 4)
        renderer.context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: Compositor.displaySpace)
        return rgba
    }
}

private var failures: [String] = []
private func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) { failures.append("\(file):\(line): \(message)") }
private func expectTrue(_ value: Bool, _ message: String = "Expected true", file: StaticString = #fileID, line: UInt = #line) { if !value { fail(message, file: file, line: line) } }
private func expectFalse(_ value: Bool, file: StaticString = #fileID, line: UInt = #line) { expectTrue(!value, "Expected false", file: file, line: line) }
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) { expectTrue(a == b, "\(a) != \(b)", file: file, line: line) }
private func expectEqual(_ a: Float, _ b: Float, accuracy: Float, file: StaticString = #fileID, line: UInt = #line) { expectTrue(abs(a-b) <= accuracy, "\(a) differs from \(b)", file: file, line: line) }
private func expectGreater<T: Comparable>(_ a: T, _ b: T, _ message: String = "Expected greater", file: StaticString = #fileID, line: UInt = #line) { expectTrue(a > b, message, file: file, line: line) }
private func expectLess<T: Comparable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) { expectTrue(a < b, "Expected less", file: file, line: line) }
private func expectAtMost<T: Comparable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) { expectTrue(a <= b, "Expected at most", file: file, line: line) }
private func expectNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) { expectTrue(value != nil, "Expected value", file: file, line: line) }
private func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line) { do { _ = try value(); fail("Expected error", file: file, line: line) } catch {} }
private func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw StudioError.encodeFailed }; return value }

@main struct CoreValidation {
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--fixtures" {
            do { try makeFixtures(at: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
            catch { print(error); exit(1) }
        }
        let suite = CompositionTests()
        let cases: [(String, () throws -> Void)] = [
            ("Seamless layout across 15 count/ratio combinations", suite.testSeamlessGeometryAcrossEveryLayout),
            ("Arbitrary aspect ratio, fit and recoverable dragging", suite.testFitAndDragForAnyAspect),
            ("Mixed inputs and HDR-off produce SDR JPEG", suite.testHDRGatingAndSDRExport),
            ("Real HDR JPEG + HEIC gain map round trips", suite.testActualHDRGainMapRoundTripBothFormats),
            ("Frame, shadow and crop appear in output pixels", suite.testFrameShadowAndCropAreInRenderedPixels),
            ("Preview/export geometry and color match", suite.testPreviewAndExportShareGeometry),
            ("Incomplete composition export is rejected", suite.testIncompleteExportRejected)
        ]
        for (name, test) in cases {
            let before = failures.count
            do { try test() } catch { failures.append("\(name): \(error)") }
            print("\(failures.count == before ? "PASS" : "FAIL")  \(name)")
        }
        for failure in failures { print(failure) }
        print("\(cases.count) checks; \(failures.count) failures")
        exit(failures.isEmpty ? 0 : 1)
    }
}

private func makeFixtures(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let renderer = Compositor()
    for i in 1...3 {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: i == 3 ? 1600 : 900)
        let colorA = [CIColor(red: 0.15, green: 0.38, blue: 0.49), CIColor(red: 0.67, green: 0.3, blue: 0.18), CIColor(red: 0.15, green: 0.38, blue: 0.28)][i-1]
        var image = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: rect.width, y: rect.height), "inputColor0": colorA, "inputColor1": CIColor(red: 0.92, green: 0.8, blue: 0.56)])!.outputImage!.cropped(to: rect)
        for column in 0..<8 {
            let marker = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: column == i ? 0.8 : 0.15))
                .cropped(to: CGRect(x: Double(column) * 200 + 20, y: rect.height * 0.2, width: 80, height: rect.height * 0.6))
            image = marker.composited(over: image)
        }
        let top = CIImage(color: CIColor(red: 0.92, green: 0.94, blue: 0.96)).cropped(to: CGRect(x: 0, y: rect.height - 60, width: rect.width, height: 60))
        image = top.composited(over: image)
        let hdr = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.5])
        let options: [CIImageRepresentationOption: Any] = [.hdrImage: hdr]
        let data = i == 2 ? renderer.context.heifRepresentation(of: image, format: .RGBA8, colorSpace: Compositor.exportSpace, options: options) : renderer.context.jpegRepresentation(of: image, colorSpace: Compositor.exportSpace, options: options)
        try unwrap(data).write(to: directory.appendingPathComponent("Test-\(i)-HDR.\(i == 2 ? "heic" : "jpg")"))
        if i == 1 {
            try unwrap(renderer.context.jpegRepresentation(of: image, colorSpace: Compositor.exportSpace, options: [:])).write(to: directory.deletingLastPathComponent().appendingPathComponent("Test-SDR.jpg"))
        }
    }
    print("Created HDR/SDR test fixtures at \(directory.path)")
}
