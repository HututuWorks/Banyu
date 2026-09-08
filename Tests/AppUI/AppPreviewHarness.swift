import SwiftUI
import UIKit

@MainActor
private struct AppReviewRoute: View {
    let page: String
    @State private var path: [String]

    init(page: String) {
        self.page = page
        _path = State(initialValue: [page])
    }

    var body: some View {
        if page == "home" { SetupView() }
        else {
            NavigationStack(path: $path) {
                Color.clear.navigationTitle("伴语")
                    .navigationDestination(for: String.self) { name in
                        switch name {
                        case "services": TranslationServicesView()
                        case "qwen": QwenTranslationSettingsView()
                        case "custom": CustomTranslationSettingsView()
                        case "keyboards": KeyboardSetupView()
                        case "tryout": KeyboardTryoutView()
                        case "about": AboutView()
                        default: OpenSourceNoticesView()
                        }
                    }
            }
        }
    }
}

@MainActor
enum AppPreviewHarness {
    static var records: [[String: Any]] = []
    static var assertions = 0
    static var directory: URL {
        guard let path = ProcessInfo.processInfo.environment["BANYU_REVIEW_OUTPUT"] else {
            preconditionFailure("Run the review through scripts/test-app-ui.sh")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    struct Sample {
        let page: String
        let width: CGFloat
        let height: CGFloat
        let dark: Bool
        let large: Bool
        var name: String {
            "\(page)-\(Int(width))-\(dark ? "dark" : "light")\(large ? "-accessibility2" : "")"
        }
    }

    static func run() async throws {
        UIView.setAnimationsEnabled(false)
        check(UIImage(named: "BrandLogo", in: .main, compatibleWith: nil) != nil,
              "Original BrandLogo loads from the compiled asset catalog")
        let pages = ["home", "about", "services", "qwen", "custom", "keyboards", "tryout"]
        var samples = [Sample]()
        for dark in [false, true] {
            for page in pages {
                samples.append(.init(page: page, width: 393, height: 852, dark: dark, large: false))
            }
        }
        for page in ["home", "keyboards"] {
            samples.append(.init(page: page, width: 320, height: 700, dark: false, large: false))
        }
        for page in ["home", "custom"] {
            samples.append(.init(page: page, width: 393, height: 852, dark: false, large: true))
        }
        if let only = ProcessInfo.processInfo.environment["BANYU_REVIEW_ONLY"] {
            samples = samples.filter { $0.name.contains(only) }
            precondition(!samples.isEmpty, "BANYU_REVIEW_ONLY matched no samples")
        }
        for sample in samples { try await render(sample) }
        let report: [String: Any] = [
            "schemaVersion": 1, "passed": true, "assertions": assertions, "screens": records,
            "renderer": "Native Mac Catalyst SwiftUI inside a real UIKit UIApplication/Window; not an iPhone screenshot",
            "brandLogo": "Loaded successfully from the compiled production asset catalog",
            "isolation": "Disposable source copies; in-memory settings; cloud transports throw; Apple availability stubbed and preparation disabled; no credentials used",
            "limitations": "Geometry checks cover roots and native scroll frames; clipping still requires image review. Accessibility2 exercises layout branches, but Catalyst semantic fonts do not reproduce iPhone scaling. Phone keyboard behavior and registration are not tested."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("app-verification.json"))
        print("PASS: \(assertions) checks; \(records.count) native SwiftUI samples")
    }

    static func render(_ sample: Sample) async throws {
        PreviewSettingsPersistence.shared.reset()
        let root = UIView(frame: CGRect(x: 0, y: 0, width: sample.width, height: sample.height))
        let style: UIUserInterfaceStyle = sample.dark ? .dark : .light
        root.overrideUserInterfaceStyle = style
        let wrapper = UIViewController()
        wrapper.view = root
        let host = UIHostingController(rootView: AppReviewRoute(page: sample.page)
            .preferredColorScheme(sample.dark ? .dark : .light)
            .environment(\.dynamicTypeSize, sample.large ? .accessibility2 : .large)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        host.overrideUserInterfaceStyle = style
        host.traitOverrides.preferredContentSizeCategory = sample.large ? .accessibilityExtraExtraLarge : .large
        wrapper.addChild(host)
        root.addSubview(host.view)
        host.didMove(toParent: wrapper)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: root.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        // A fixed native content viewport, without fabricated iPhone status chrome.
        let window = UIWindow(frame: root.frame)
        window.rootViewController = wrapper
        window.overrideUserInterfaceStyle = style
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        root.setNeedsLayout()
        root.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        check(abs(host.view.bounds.width - sample.width) < 0.1, "Hosting width matches viewport")
        check(abs(host.view.bounds.height - sample.height) < 0.1, "Hosting height matches viewport")
        check(host.view.window != nil, "SwiftUI host is in a real window")
        check(host.traitCollection.userInterfaceStyle == style, "Native color style matches requested style")
        let scrolls = descendants(root).compactMap { $0 as? UIScrollView }
            .filter { !$0.isHidden && $0.bounds.width > 100 && $0.bounds.height > 60 }
        var scrollRecords = [[String: Any]]()
        for scroll in scrolls {
            let rect = scroll.convert(scroll.bounds, to: root)
            check(rect.minX >= -0.5 && rect.maxX <= sample.width + 0.5, "Scroll viewport stays inside horizontal bounds")
            check(scroll.contentSize.width <= scroll.bounds.width + 1, "No horizontal content overflow")
            scrollRecords.append([
                "frame": NSCoder.string(for: rect), "contentSize": NSCoder.string(for: scroll.contentSize)
            ])
        }
        try save(root, name: sample.name)
        if let scrolling = scrolls.filter({ $0.contentSize.height > $0.bounds.height + 30 })
            .max(by: { $0.bounds.height < $1.bounds.height }) {
            let bottom = max(-scrolling.adjustedContentInset.top,
                             scrolling.contentSize.height - scrolling.bounds.height + scrolling.adjustedContentInset.bottom)
            scrolling.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            root.setNeedsLayout()
            root.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            check(abs(scrolling.contentOffset.y - bottom) < 1, "Final content reachable by vertical scroll")
            try save(root, name: sample.name + "-bottom")
        }
        records.append([
            "name": sample.name, "page": sample.page, "width": sample.width, "height": sample.height,
            "accessibilityBranch": sample.large, "dark": sample.dark, "nativeScrolls": scrollRecords
        ])
        window.isHidden = true
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        print("RENDER_OK \(sample.name)")
    }

    static func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func save(_ view: UIView, name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: view.bounds.size, format: format)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        guard let data = image.pngData() else { throw NSError(domain: "render", code: 1) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        assertions += 1
    }
}
