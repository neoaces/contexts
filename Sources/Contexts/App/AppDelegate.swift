import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PanelModel(store: BlockStore())
    private var panelController: PanelController?
    private var hotZones: EdgeHotZones?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let controller = PanelController(model: model)
        hotZones = EdgeHotZones { screen in
            controller.show(on: screen, pointerY: NSEvent.mouseLocation.y)
        }
        panelController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForTermination()
    }
}
