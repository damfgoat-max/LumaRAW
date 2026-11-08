import SwiftUI

@main
struct LumaRAWApp: App {
    @StateObject private var lutManager: LUTManager
    @StateObject private var viewModel: CameraViewModel

    init() {
        let manager = LUTManager()
        _lutManager = StateObject(wrappedValue: manager)
        _viewModel = StateObject(wrappedValue: CameraViewModel(lutManager: manager))
    }

    var body: some Scene {
        WindowGroup {
            CameraView(viewModel: viewModel)
                .environmentObject(lutManager)
                .preferredColorScheme(.dark)
                // "Open in…" / share-sheet import of .cube files.
                .onOpenURL { url in
                    lutManager.importFromURL(url)
                }
        }
    }
}
