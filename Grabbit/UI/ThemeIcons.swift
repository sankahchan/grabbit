import SwiftUI

/// Icons that adapt to the active theme. Aura swaps SF Symbols for the
/// bundled Lucide line-icon set (free, ISC); every other theme keeps the
/// system symbols so the classic look is untouched.
struct ThemedIcon: View {
    /// Asset catalog name, e.g. "IconDownloads".
    var asset: String
    /// SF Symbol fallback.
    var system: String
    var size: CGFloat = 15

    var body: some View {
        if Neo.shape.lineIcons {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: system)
        }
    }
}
