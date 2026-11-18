import SwiftUI

/// iOS 26's full-width Back swipe competes with horizontal ink. The explicit Back
/// button remains available; restore the navigation controller's settings when reading/leaving.
struct NavigationInkProtection: UIViewControllerRepresentable {
    var writing: Bool
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.writing = writing
        controller.updateProtection()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController {
        var writing = false
        private weak var protectedNavigation: UINavigationController?
        private var edgeEnabled: Bool?
        private var contentEnabled: Bool?

        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateProtection() }
        override func viewWillDisappear(_ animated: Bool) { restore(); super.viewWillDisappear(animated) }

        func updateProtection() {
            guard writing else { restore(); return }
            guard let navigation = navigationController else { return }
            if protectedNavigation !== navigation {
                restore()
                protectedNavigation = navigation
                edgeEnabled = navigation.interactivePopGestureRecognizer?.isEnabled
                contentEnabled = navigation.interactiveContentPopGestureRecognizer?.isEnabled
            }
            navigation.interactivePopGestureRecognizer?.isEnabled = false
            navigation.interactiveContentPopGestureRecognizer?.isEnabled = false
        }
        func restore() {
            if let edgeEnabled { protectedNavigation?.interactivePopGestureRecognizer?.isEnabled = edgeEnabled }
            if let contentEnabled { protectedNavigation?.interactiveContentPopGestureRecognizer?.isEnabled = contentEnabled }
            protectedNavigation = nil; edgeEnabled = nil; contentEnabled = nil
        }
    }
}
