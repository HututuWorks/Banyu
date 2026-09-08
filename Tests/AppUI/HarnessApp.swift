import UIKit
import Darwin
@main
@MainActor
final class HarnessApplicationDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DispatchQueue.main.async {
            Task { @MainActor in
                do { try await AppPreviewHarness.run(); exit(0) }
                catch { print("HARNESS ERROR", error); exit(1) }
            }
        }
        return true
    }
}
