import SwiftUI
@main struct ResolveScopesPadApp:App {
    @StateObject private var model=CompanionModel()
    @Environment(\.scenePhase) private var phase
    var body:some Scene {
        WindowGroup {CompanionScreen(model:model).preferredColorScheme(.dark)
            .onChange(of:phase) {value in
                // Release the Direct session when the app leaves the foreground.
                if value == .background {model.disconnect()}
            }
        }
    }
}
