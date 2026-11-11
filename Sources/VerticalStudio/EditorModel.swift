import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VerticalCore

@MainActor final class EditorModel: ObservableObject {
    @Published var slots = (0..<3).map { _ in Slot() }
    @Published var settings = CompositionSettings()
    @Published var hasSelection = true
    @Published var selected = 0 { didSet { hasSelection = true } }
    func deselect() { hasSelection = false }
    @Published var preview: CGImage?
    @Published var busy = false
    @Published var previewPending = false
    @Published var status = "选择照片，开始一张竖幅作品"
    @Published var error: String?
    @Published var showResetConfirmation = false
    @Published var revision = 0
    private static let lastImportDirectoryKey = "lastImportDirectory"
    // Workspace destination is intentionally in memory only; New starts a fresh destination.
    private var firstImportDirectory: URL?
    private var lastImportDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastImportDirectoryKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    private func availableDirectory(_ url: URL?) -> URL? {
        guard let url else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }
    private var exportedRevision = 0
    private var closeApproved = false
    private var previewGeneration = 0
    private var previewJob: DispatchWorkItem?
    private let queue = DispatchQueue(label: "studio.render", qos: .userInitiated)
    private let compositor = Compositor()
    var composition: Composition { Composition(slots: slots, settings: settings) }
    var filled: Int { slots.compactMap(\.photo).count }
    var dirty: Bool { filled > 0 && revision != exportedRevision }
    var containsSDRPhoto: Bool { slots.compactMap(\.photo).contains { !$0.hasGainMap } }
    var hdrExplanation: String {
        if filled == 0 { return "所有照片都含 gain map 时，可开启 HDR 编辑与导出。" }
        if containsSDRPhoto { return "包含 SDR 照片，整张作品已自动使用 SDR。" }
        return settings.hdrEnabled ? "正在保留高光层次 · 导出含 HDR gain map" : "HDR 已关闭 · 使用 SDR 显示与 JPEG 导出"
    }
    func changed() { closeApproved = false; revision += 1; requestPreview() }
    func updateSettings(_ update: (inout CompositionSettings) -> Void) { update(&settings); changed() }
    func setCount(_ count: Int) {
        guard count != slots.count else { return }
        if count < slots.count && slots[count...].contains(where: { $0.photo != nil }) {
            let alert = NSAlert()
            alert.messageText = "减少到 \(count) 张照片？"
            alert.informativeText = "最后 \(slots.count - count) 个区块里的照片及位置调整将被移除。"
            alert.addButton(withTitle: "保留当前数量"); alert.addButton(withTitle: "移除多余区块")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if count > slots.count { slots += (slots.count..<count).map { _ in Slot() } }
        else { slots = Array(slots.prefix(count)) }
        settings.count = count; selected = min(selected, count - 1); changed()
    }
    func choosePhotos(replace index: Int? = nil) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = availableDirectory(lastImportDirectory)
        panel.allowedContentTypes = [.jpeg, .heic, .heif]
        panel.allowsMultipleSelection = index == nil
        panel.message = index == nil ? "选择 2–4 张照片；导入后可调整顺序，也可逐个添加。" : "替换当前区块中的照片"
        panel.prompt = "导入照片"
        if panel.runModal() == .OK { importPhotos(panel.urls, replace: index) }
    }
    func importPhotos(_ urls: [URL], replace index: Int? = nil) {
        guard !busy, !urls.isEmpty else { return }
        var targets: [Int]
        var replacementCount: Int?
        if let index { targets = [index] }
        else {
            if filled == 0 && (2...4).contains(urls.count) {
                replacementCount = urls.count
            }
            targets = replacementCount.map { Array(0..<$0) } ?? slots.indices.filter { slots[$0].photo == nil }
        }
        guard urls.count <= targets.count else {
            error = "当前有 \(targets.count) 个空区块，但选择了 \(urls.count) 张照片。请调整照片数量，或点选照片后使用替换。"; return
        }
        busy = true; status = "正在读取照片与 HDR 信息…"
        let assignedTargets = targets
        let newCount = replacementCount
        queue.async { [weak self] in
            let result = Result { try urls.map { try Photo.load(url: $0) } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let photos):
                    if self.firstImportDirectory == nil {
                        self.firstImportDirectory = urls[0].deletingLastPathComponent()
                    }
                    UserDefaults.standard.set(urls[urls.count - 1].deletingLastPathComponent().path,
                                              forKey: Self.lastImportDirectoryKey)
                    if let newCount { self.settings.count = newCount; self.slots = (0..<newCount).map { _ in Slot() } }
                    for (offset, photo) in photos.enumerated() { self.slots[assignedTargets[offset]] = Slot(photo: photo) }
                    self.selected = assignedTargets[0]
                    self.status = "已导入 \(photos.count) 张照片 · 拖动照片调整构图"
                    self.changed()
                case .failure(let error): self.error = error.localizedDescription; self.status = "导入失败"
                }
            }
        }
    }
    func removeSelected() { guard hasSelection else { return }; slots[selected] = Slot(); changed() }
    func moveSelected(_ delta: Int) {
        guard hasSelection else { return }
        let destination = selected + delta
        guard slots.indices.contains(destination) else { return }
        slots.swapAt(selected, destination); selected = destination; changed()
    }
    func place(_ placement: Placement, at index: Int) {
        guard slots.indices.contains(index), slots[index].photo != nil else { return }
        slots[index].placement = composition.clamped(placement, index: index); changed()
    }
    func setZoom(_ value: Double) {
        guard hasSelection else { return }
        var p = slots[selected].placement; p.zoom = value; place(p, at: selected)
    }
    func fit() { guard hasSelection else { return }; place(composition.fittedPlacement(index: selected), at: selected) }
    func fill() { guard hasSelection else { return }; place(Placement(), at: selected) }
    func center() { guard hasSelection else { return }; var p = slots[selected].placement; p.x = 0; p.y = 0; place(p, at: selected) }
    func newComposition() {
        if dirty { showResetConfirmation = true } else { reset() }
    }
    func reset() {
        previewGeneration += 1; previewJob?.cancel()
        settings = CompositionSettings(); slots = (0..<3).map { _ in Slot() }; selected = 0
        revision = 0; exportedRevision = 0; preview = nil
        firstImportDirectory = nil
        status = "工作区已清空 · 选择照片开始新作品"; requestPreview()
    }
    func requestPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        let snapshot = composition
        previewJob?.cancel(); previewPending = true
        let job = DispatchWorkItem { [weak self, compositor] in
            let result = autoreleasepool { compositor.preview(snapshot) }
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                self.preview = result; self.previewPending = false
            }
        }
        previewJob = job
        queue.asyncAfter(deadline: .now() + 0.025, execute: job)
    }
    func export() {
        guard !busy, composition.isComplete else { return }
        let snapshot = composition, snapshotRevision = revision
        let panel = NSSavePanel()
        panel.directoryURL = availableDirectory(firstImportDirectory) ?? availableDirectory(lastImportDirectory)
        panel.allowedContentTypes = [snapshot.exportFormat == .heic ? .heic : .jpeg]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyMMdd"
        let date = dateFormatter.string(from: Date())
        // Use the filename-safe full-width colon; ASCII ':' is special in macOS file dialogs.
        let ratio = snapshot.settings.ratio.rawValue.replacingOccurrences(of: ":", with: "：")
        panel.nameFieldStringValue = "verti-\(date)-\(ratio)-\(snapshot.isHDR ? "HDR" : "SDR").\(snapshot.exportFormat.ext)"
        panel.message = "\(Int(settings.size.width)) × \(Int(settings.size.height)) 像素 · \(snapshot.isHDR ? "HDR gain map" : "SDR")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "正在合成并导出\(snapshot.isHDR ? " HDR gain map" : "")…"
        queue.async { [weak self, compositor] in
            let result = Result { try autoreleasepool { try compositor.export(snapshot, to: url) } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success:
                    self.exportedRevision = snapshotRevision
                    self.status = "已导出 · \(url.lastPathComponent)"
                case .failure(let error): self.error = error.localizedDescription; self.status = "导出失败 · 工作区已保留"
                }
            }
        }
    }
    func confirmClose() -> Bool {
        if closeApproved { return true }
        if busy { NSSound.beep(); return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "当前作品尚未导出"
        alert.informativeText = "关闭后，照片和构图调整不会保存。请先导出，或选择放弃。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃并关闭")
        closeApproved = alert.runModal() == .alertSecondButtonReturn
        return closeApproved
    }
}
