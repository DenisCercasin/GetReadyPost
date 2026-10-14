import SwiftData
import SwiftUI

@main
struct UnpostedApp: App {
    /// Built explicitly so a schema failure degrades to an in-memory store with a visible warning
    /// instead of crashing on launch.
    private let container: ModelContainer
    private let containerErrorMessage: String?

    init() {
        let schema = Schema(AppSchema.models)
        do {
            container = try ModelContainer(for: schema)
            containerErrorMessage = nil
        } catch {
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // A container with an in-memory configuration cannot realistically fail; if it does,
            // there is nothing left to fall back to.
            container = try! ModelContainer(for: schema, configurations: fallback)
            containerErrorMessage = """
            Unposted couldn't open its local database, so this session won't be saved. \
            (\(error.localizedDescription))
            """
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(containerErrorMessage: containerErrorMessage)
        }
        .modelContainer(container)
    }
}
