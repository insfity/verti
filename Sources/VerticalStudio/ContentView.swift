import SwiftUI
import AppKit
import CoreImage
import VerticalCore

private let ink = Color(red: 0.18, green: 0.20, blue: 0.19)
private let accent = Color(red: 0.81, green: 0.35, blue: 0.21)
private let paper = Color(red: 0.98, green: 0.975, blue: 0.96)

struct ContentView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            topbar
            Divider()
            HStack(spacing: 0) {
                leftPanel.frame(width: 210)
                Divider()
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: 260)
            }
            Divider()
            footer
        }
        .background(paper).foregroundStyle(ink).tint(accent)
        .frame(minWidth: 1040, minHeight: 720)
        .preferredColorScheme(.light)
        .alert("清空当前工作区？", isPresented: $model.showResetConfirmation) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃修改并新建", role: .destructive) { model.reset() }
        } message: {
            Text("当前作品还有未导出的内容。新建会移除所有照片和调整，且不会保存工程文件。")
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear { model.requestPreview() }
    }
    private var topbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1.fill").rotationEffect(.degrees(90))
                .font(.system(size: 23)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("竖影").font(.system(size: 20, weight: .semibold))
                Text("VERTICAL STUDIO").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2)
            }
            Rectangle().fill(ink.opacity(0.14)).frame(width: 1, height: 28).padding(.horizontal, 8)
            Text("把横向的瞬间，连成一个故事。").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { model.newComposition() } label: { Label("新建", systemImage: "plus") }
                .buttonStyle(.bordered).disabled(model.busy)
            Button { model.choosePhotos() } label: { Label("导入照片", systemImage: "photo.badge.plus") }
                .buttonStyle(.bordered).disabled(model.busy)
            Button { model.export() } label: { Label("导出图片", systemImage: "square.and.arrow.up").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).disabled(!model.composition.isComplete || model.busy)
        }.padding(.horizontal, 22).frame(height: 62)
    }
    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading("01", "布局与照片")
            VStack(alignment: .leading, spacing: 9) {
                fieldTitle("竖屏比例")
                Picker("竖屏比例", selection: setting(\.ratio)) {
                    ForEach(PortraitRatio.allCases) { ratio in Text("\(ratio.rawValue)   \(ratio.subtitle)").tag(ratio) }
                }.labelsHidden().pickerStyle(.menu)
                fieldTitle("照片数量").padding(.top, 5)
                Picker("照片数量", selection: Binding(get: { model.settings.count }, set: { model.setCount($0) })) {
                    ForEach(2...4, id: \.self) { Text("\($0) 张").tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            HStack {
                fieldTitle("照片顺序")
                Spacer()
                Text("\(model.filled) / \(model.settings.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.top, 5)
            VStack(spacing: 8) {
                ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in photoRow(index, slot) }
            }
            HStack(spacing: 8) {
                Button { model.moveSelected(-1) } label: { Image(systemName: "arrow.up") }.help("向上移动照片")
                    .disabled(!model.hasSelection || model.selected == 0)
                Button { model.moveSelected(1) } label: { Image(systemName: "arrow.down") }.help("向下移动照片")
                    .disabled(!model.hasSelection || model.selected == model.slots.count - 1)
                Spacer()
                Button { model.choosePhotos(replace: model.selected) } label: { Image(systemName: "arrow.triangle.2.circlepath") }.help("替换选中照片").disabled(!model.hasSelection)
                Button { model.removeSelected() } label: { Image(systemName: "trash") }.help("移除选中照片")
                    .disabled(!model.hasSelection || model.slots[model.selected].photo == nil)
            }.buttonStyle(.bordered)
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "hand.draw").font(.system(size: 21)).foregroundStyle(accent)
                Text("让构图随手而动").font(.system(size: 12, weight: .medium))
                Text("拖动虚线框，松开应用位置\n滚轮 / 双指捏合缩放\n双击照片恢复铺满\n也可将照片拖入画布")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        }.padding(18).disabled(model.busy)
    }
    private func photoRow(_ index: Int, _ slot: Slot) -> some View {
        Button {
            model.selected = index
            if slot.photo == nil { model.choosePhotos(replace: index) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(ink.opacity(0.06))
                    if let photo = slot.photo { PhotoThumbnail(photo: photo) }
                    else { Image(systemName: "plus").foregroundStyle(.secondary) }
                }.frame(width: 52, height: 42).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.photo?.name ?? "添加照片").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if let photo = slot.photo {
                        Text("\(Int(photo.size.width)) × \(Int(photo.size.height))  ·  \(photo.hasGainMap ? "HDR" : "SDR")")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    } else { Text("JPEG / HEIC").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Text("\(index + 1)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(model.hasSelection && model.selected == index ? accent : .secondary)
            }.padding(8)
                .background(model.hasSelection && model.selected == index ? accent.opacity(0.07) : Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.hasSelection && model.selected == index ? accent.opacity(0.65) : ink.opacity(0.08), lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private var workspace: some View {
        VStack(spacing: 0) {
            HStack {
                Text("画布预览").font(.system(size: 11, weight: .medium))
                Spacer()
                Text(model.composition.isHDR ? "HDR" : "SDR").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(model.composition.isHDR ? accent.opacity(0.12) : ink.opacity(0.06), in: Capsule())
                Text(model.settings.ratio.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.top, 10)
            CanvasView(model: model)
            HStack(spacing: 6) {
                Image(systemName: "viewfinder")
                Text(model.hasSelection ? "选中第 \(model.selected + 1) 张 · \(Int(model.slots[model.selected].placement.zoom * 100))%" : "整体预览 · 点击照片继续编辑")
                if model.previewPending { Text("· 更新中") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 8)
        }.background(Color(red: 0.91, green: 0.915, blue: 0.90))
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                sectionHeading("02", "照片构图")
                VStack(alignment: .leading, spacing: 12) {
                    valueSlider("缩放", value: Binding(get: { model.slots[model.selected].placement.zoom }, set: { model.setZoom($0) }), range: model.composition.minimumZoom(index: model.selected)...6, label: "\(Int(model.slots[model.selected].placement.zoom * 100))%")
                    HStack(spacing: 6) {
                        Button("铺满") { model.fill() }
                        Button("完整显示") { model.fit() }
                        Button("居中") { model.center() }
                    }.buttonStyle(.bordered).controlSize(.small)
                }.disabled(!model.hasSelection || model.slots[model.selected].photo == nil)
                Divider()
                sectionHeading("03", "画框与留白")
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 7) {
                        Button("无缝") { model.updateSettings { $0.border = 0; $0.gap = 0; $0.shadow = false } }
                        Button("留白") { model.updateSettings { $0.border = 0.035; $0.gap = 0.018 } }
                        Button("画廊") { model.updateSettings { $0.border = 0.075; $0.gap = 0.045; $0.shadow = true } }
                    }.buttonStyle(.bordered).controlSize(.small)
                    valueSlider("整体边框", value: setting(\.border), range: 0...0.14, label: pixels(model.settings.border))
                    valueSlider("照片间隙", value: setting(\.gap), range: 0...0.10, label: pixels(model.settings.gap))
                    HStack {
                        Text("画框颜色").font(.system(size: 11))
                        Spacer()
                        ForEach([FrameColor.paper, FrameColor(1,1,1), FrameColor(0.10,0.12,0.12)], id: \.r) { c in
                            Button { model.updateSettings { $0.color = c } } label: {
                                Circle().fill(Color(red:c.r, green:c.g, blue:c.b)).frame(width: 17, height: 17)
                                    .overlay(Circle().stroke(ink.opacity(0.18), lineWidth: 1))
                            }.buttonStyle(.plain).help("预设画框颜色")
                        }
                        ColorPicker("自定义画框颜色", selection: Binding(get: {
                            let c = model.settings.color; return Color(red: c.r, green: c.g, blue: c.b)
                        }, set: { color in
                            if let c = NSColor(color).usingColorSpace(.sRGB) {
                                model.updateSettings { $0.color = FrameColor(c.redComponent, c.greenComponent, c.blueComponent) }
                            }
                        }), supportsOpacity: false).labelsHidden()
                    }
                    Toggle("照片投影", isOn: setting(\.shadow)).font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                        .disabled(!model.settings.hasFrame)
                    if model.settings.shadow && model.settings.hasFrame {
                        valueSlider("浓度", value: setting(\.shadowOpacity), range: 0...0.75, label: "\(Int(model.settings.shadowOpacity * 100))%")
                        valueSlider("柔和度", value: setting(\.shadowBlur), range: 0.001...0.05, label: pixels(model.settings.shadowBlur))
                        valueSlider("偏移", value: setting(\.shadowOffset), range: 0...0.05, label: pixels(model.settings.shadowOffset))
                    }
                }
                Divider()
                sectionHeading("04", "色彩与导出")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("保留 HDR", isOn: Binding(
                        get: { model.settings.hdrEnabled && !model.containsSDRPhoto },
                        set: { enabled in
                            guard !model.containsSDRPhoto else { return }
                            model.updateSettings { $0.hdrEnabled = enabled }
                        }
                    )).font(.system(size: 11, weight: .medium)).toggleStyle(.switch).controlSize(.small)
                        .disabled(model.containsSDRPhoto)
                    Text(model.hdrExplanation).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    HStack {
                        Text("格式").font(.system(size: 11))
                        Spacer()
                        if model.composition.isHDR {
                            Picker("格式", selection: setting(\.format)) { ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 135)
                        } else { Text("JPEG · SDR").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                    Picker("长边像素", selection: setting(\.longEdge)) {
                        Text("1920 px").tag(1920); Text("2560 px").tag(2560); Text("3840 px").tag(3840); Text("6000 px").tag(6000); Text("7680 px").tag(7680)
                    }.font(.system(size: 11))
                    valueSlider("图像质量", value: setting(\.quality), range: 0.6...1, label: "\(Int(model.settings.quality * 100))%")
                    Text("\(Int(model.settings.size.width)) × \(Int(model.settings.size.height)) px · Display P3")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(18)
        }.disabled(model.busy)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.mini) }
            else { Circle().fill(model.dirty ? accent : Color.green.opacity(0.7)).frame(width: 5, height: 5) }
            Text(model.status).lineLimit(1)
            Spacer()
            Text(model.dirty ? "有未导出的修改" : "仅导出图片 · 不保存工程")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 32)
    }
    private func setting<T>(_ keyPath: WritableKeyPath<CompositionSettings,T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }
    private func pixels(_ value: Double) -> String { "\(Int((model.settings.size.width * value).rounded())) px" }
    private func sectionHeading(_ number: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
    }
    private func fieldTitle(_ title: String) -> some View { Text(title).font(.system(size: 11)).foregroundStyle(.secondary) }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.mini).accessibilityLabel(title)
        }
    }
}

private struct PhotoThumbnail: View {
    let photo: Photo
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Color.clear }
        }.task(id: photo.id) {
            let photo = self.photo
            let result = await Task.detached(priority: .utility) {
                let context = CIContext(options: [.cacheIntermediates: false])
                let scale = min(1, 160 / max(photo.size.width, photo.size.height))
                let reduced = photo.sdr.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return context.createCGImage(reduced, from: reduced.extent)
            }.value
            if let result { image = NSImage(cgImage: result, size: photo.size) }
        }
    }
}
