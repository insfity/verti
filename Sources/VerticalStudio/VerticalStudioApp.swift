import SwiftUI
import AppKit

@main struct VerticalStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = EditorModel()
    var body: some Scene {
        Window("竖影 · Vertical Studio", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .background(WindowAccessor(model: model))
        }
        .defaultSize(width: 1240, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建拼图") { model.newComposition() }.keyboardShortcut("n").disabled(model.busy)
                Button("导入照片…") { model.choosePhotos() }.keyboardShortcut("o").disabled(model.busy)
                Button("导出图片…") { model.export() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.composition.isComplete || model.busy)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (model?.confirmClose() ?? true) ? .terminateNow : .terminateCancel
    }
}
struct WindowAccessor: NSViewRepresentable {
    let model: EditorModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.delegate = context.coordinator
            view.window?.titlebarAppearsTransparent = true
            view.window?.isMovableByWindowBackground = false
            view.window?.setFrameAutosaveName("VerticalStudioWindow")
            (NSApp.delegate as? AppDelegate)?.model = model
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: EditorModel
        init(model: EditorModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool { model.confirmClose() }
    }
}
