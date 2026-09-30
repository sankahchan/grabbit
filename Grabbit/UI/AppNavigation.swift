import Foundation
import Observation

/// Cross-view navigation state. The URL-scheme handlers (extension grabs,
/// magnet links, imports) switch the sidebar to the tab that shows the
/// incoming task instead of leaving the user wherever they were.
@Observable
final class AppNavigation {
    var selection: SidebarSelection = .downloads

    init() {}
}
