import SwiftUI
import AppKit

// MARK: - Hex helper

extension Color {
    /// Creates a Color from a 0xRRGGBB hex value.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Neo-brutalist palette

/// Neo-brutalist palette for Grabbit: thick ink borders, hard offset shadows,
/// flat bright accents.
///
/// The bright accents are fixed; `ink` / `paper` adapt to the color scheme —
/// pass the view's scheme explicitly:
///
/// ```swift
/// @Environment(\.colorScheme) private var scheme
/// ...
/// .foregroundStyle(Neo.ink(scheme))
/// .neoCard() // background defaults to theme-aware paper
/// ```
enum NeoPalette {
    // MARK: Bright accents (identical in light & dark)

    static let yellow = Color(hex: 0xFFD02F)
    static let pink   = Color(hex: 0xFF90E8)
    static let blue   = Color(hex: 0x7DD3FC)
    static let green  = Color(hex: 0x86EFAC)
    static let orange = Color(hex: 0xFB923C)
    static let purple = Color(hex: 0xC4B5FD)
    static let red    = Color(hex: 0xFF6B6B)

    // MARK: Scheme-adaptive neutrals

    static let inkLight   = Color(hex: 0x111111)
    static let paperLight = Color(hex: 0xF8F2E3)
    static let inkDark    = Color(hex: 0xF2EDE3)
    static let paperDark  = Color(hex: 0x17171C)

    /// Near-black in light mode, near-white in dark mode.
    /// Use for borders, text, and hard shadows.
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? inkDark : inkLight
    }

    /// Warm paper in light mode, deep charcoal in dark mode.
    /// Default card background.
    static func paper(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? paperDark : paperLight
    }

    /// Foreground for a filled background: dark ink on bright fills
    /// (yellow/green/blue/…), scheme-adaptive ink on dark fills.
    /// Without this, dark mode renders white text on bright accents
    /// (white-on-yellow, white-on-green) which is unreadable.
    static func onAccent(_ bg: Color, scheme: ColorScheme) -> Color {
        isBright(bg) ? inkLight : ink(scheme)
    }

    private static func isBright(_ color: Color) -> Bool {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.299 * rgb.redComponent
            + 0.587 * rgb.greenComponent
            + 0.114 * rgb.blueComponent
        return luminance > 0.55
    }
}

/// Terse alias so call sites read `Neo.yellow`, `Neo.ink(scheme)`, …
typealias Neo = NeoPalette

// MARK: - Neo modifiers

/// Card: 3pt ink border, 6pt hard offset shadow, 14pt radius.
///
/// The offset block is a plain filled shape behind the card — NOT
/// `.shadow()`: a zero-blur shadow re-renders the *entire content* (text
/// included) as a solid ghost copy, which in dark mode is near-white and
/// looks like doubled text.
struct NeoCardModifier: ViewModifier {
    /// Pass nil (default) for theme-aware paper.
    var bg: Color?
    /// Optional bright strip along the top edge (the GistHub-style card).
    var accent: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(14)
            .background(bg ?? Neo.paper(scheme))
            .overlay(alignment: .top) {
                if let accent {
                    Rectangle()
                        .fill(accent)
                        .frame(height: 7)
                }
            }
            .clipShape(shape)
            .background(
                shape
                    .fill(Neo.ink(scheme))
                    .offset(x: 6, y: 6)
            )
            .overlay(
                shape
                    .stroke(Neo.ink(scheme), lineWidth: 3)
            )
    }
}

/// Small uppercase pill badge with a 2pt ink border.
struct NeoBadgeModifier: ViewModifier {
    var bg: Color
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Neo.ink(scheme), lineWidth: 2))
    }
}

/// Chunky neo-brutalist button: thick ink border, hard offset shadow that
/// collapses on press, plus a slight scale-down for tactile feedback.
struct NeoButtonStyle: ButtonStyle {
    var bg: Color
    var compact: Bool = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = compact ? 8 : 10
        let shift: CGFloat = configuration.isPressed ? 1 : 4
        return configuration.label
            .font(compact ? .subheadline.weight(.bold) : .headline.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(Neo.onAccent(bg, scheme: scheme))
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 6 : 10)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Hard offset block as a plain shape, not `.shadow()`: a
            // zero-blur shadow duplicates the label text as a solid ghost
            // copy (near-white in dark mode = "doubled text").
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Neo.ink(scheme))
                    .offset(x: shift, y: shift)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Neo-brutalist card. Pass `bg` to override the theme-aware paper
    /// default, and `accent` for a bright strip along the top edge.
    func neoCard(bg: Color? = nil, accent: Color? = nil) -> some View {
        modifier(NeoCardModifier(bg: bg, accent: accent))
    }

    /// Small uppercase pill badge with a 2pt ink border.
    func neoBadge(bg: Color) -> some View {
        modifier(NeoBadgeModifier(bg: bg))
    }

    /// Convenience for `.buttonStyle(NeoButtonStyle(bg: bg))`.
    func neoButton(bg: Color) -> some View {
        buttonStyle(NeoButtonStyle(bg: bg))
    }

    /// Neo-brutalist text field: 2pt ink border on paper.
    func neoTextField() -> some View {
        modifier(NeoTextFieldModifier())
    }
}

// MARK: - Progress bars

/// Renders one bordered block per download segment:
/// complete → green, partial → blue filled to its fraction, empty → paper.
struct SegmentedProgressBar: View {
    var segments: [Segment]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(segments) { segment in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Neo.paper(scheme))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fillColor(for: segment))
                            .frame(width: max(0, geo.size.width * fraction(of: segment)))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Neo.ink(scheme), lineWidth: 2)
                    )
                }
            }
        }
        .frame(height: 14)
    }

    private func fraction(of segment: Segment) -> Double {
        if segment.isComplete { return 1 }
        let total = max(segment.byteCount, 1)
        return min(1, max(0, Double(segment.receivedBytes) / Double(total)))
    }

    private func fillColor(for segment: Segment) -> Color {
        if segment.isComplete { return Neo.green }
        return segment.receivedBytes > 0 ? Neo.blue : Neo.paper(scheme)
    }
}

/// Plain neo-brutalist linear bar (used for torrents).
struct NeoLinearBar: View {
    var progress: Double
    var fill: Color = Neo.blue
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Neo.paper(scheme))
                RoundedRectangle(cornerRadius: 6)
                    .fill(fill)
                    .frame(width: geo.size.width * min(1, max(0, progress)))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Neo.ink(scheme), lineWidth: 2)
            )
        }
        .frame(height: 12)
    }
}

// MARK: - Source badge

/// Small colored badge identifying where a download came from.
struct SourceBadge: View {
    var site: SourceSite

    var body: some View {
        Text(label)
            .neoBadge(bg: color)
    }

    private var label: String {
        switch site {
        case .direct: "Direct"
        case .youtube: "YouTube"
        case .x: "X"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .telegram: "Telegram"
        case .other: "Other"
        }
    }

    private var color: Color {
        switch site {
        case .direct: Neo.green
        case .youtube: Neo.red
        case .x: Neo.yellow
        case .tiktok: Neo.pink
        case .instagram: Neo.purple
        case .telegram: Neo.blue
        case .other: Neo.paperLight
        }
    }
}

// MARK: - Neo controls

/// Chunky neo-brutalist checkbox: 2.5pt ink border, bright green fill +
/// ink checkmark when on. Replaces the system blue checkbox everywhere.
struct NeoToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isOn ? Neo.green : Neo.paper(scheme))
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Neo.ink(scheme), lineWidth: 2.5)
                        )
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Neo.onAccent(Neo.green, scheme: scheme))
                    }
                }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Neo-brutalist segmented control: 2.5pt ink border, 2pt ink dividers,
/// selected segment filled bright yellow with ink text. Replaces the
/// system segmented picker so the control reads Grabbit in both themes.
struct NeoSegmented<Value: Hashable>: View {
    struct Option: Hashable {
        let value: Value
        let title: String
        let icon: String?
    }

    @Binding var selection: Value
    let options: [Option]
    @Environment(\.colorScheme) private var scheme

    init(selection: Binding<Value>, options: [Option]) {
        _selection = selection
        self.options = options
    }

    /// Text-only options.
    init(selection: Binding<Value>, titles: [(Value, String)]) {
        _selection = selection
        options = titles.map { Option(value: $0.0, title: $0.1, icon: nil) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                segmentButton(for: options[index])
                if index < options.count - 1 {
                    Rectangle()
                        .fill(Neo.ink(scheme))
                        .frame(width: 2)
                }
            }
        }
        .background(Neo.paper(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: 2.5)
        )
    }

    private func segmentButton(for option: Option) -> some View {
        let selected = selection == option.value
        return Button {
            selection = option.value
        } label: {
            HStack(spacing: 4) {
                if let icon = option.icon {
                    Image(systemName: icon)
                }
                Text(option.title)
            }
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            // Longer localized labels (e.g. "မြန်မာ") must shrink, never
            // truncate with an ellipsis inside a segment.
            .minimumScaleFactor(0.8)
            .foregroundStyle(
                selected ? Neo.onAccent(Neo.yellow, scheme: scheme) : Neo.ink(scheme))
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(selected ? Neo.yellow : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Neo-brutalist text field: 2pt ink border on paper. Replaces
/// `.textFieldStyle(.roundedBorder)` / the borderless default.
struct NeoTextFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Neo.paper(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 2)
            )
    }
}

/// Neo-brutalist stepper: ink-bordered − / + buttons around the value.
struct NeoStepper<V: Strideable>: View {
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let label: (V) -> String
    @Environment(\.colorScheme) private var scheme

    /// Mirrors the system `Stepper(value:in:step:)` labels.
    init(
        value: Binding<V>, in range: ClosedRange<V>, step: V.Stride,
        label: @escaping (V) -> String
    ) {
        _value = value
        self.range = range
        self.step = step
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            stepButton(icon: "minus", disabled: value <= range.lowerBound) {
                set(value.advanced(by: step.negated()))
            }
            Text(label(value))
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 72)
                .multilineTextAlignment(.center)
            stepButton(icon: "plus", disabled: value >= range.upperBound) {
                set(value.advanced(by: step))
            }
        }
    }

    private func set(_ next: V) {
        if range.contains(next) { value = next }
    }

    private func stepButton(
        icon: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(Neo.ink(scheme))
                .frame(width: 26, height: 26)
                .background(Neo.paper(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Neo.ink(scheme), lineWidth: 2)
                )
                .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private extension SignedNumeric {
    /// Negation without a `-` operator constraint dance at the call site.
    func negated() -> Self { 0 - self }
}

// MARK: - Page chrome

/// Dot-grid paper, the signature neo-brutalist backdrop: warm cream in light
/// mode, deep charcoal in dark, both with a faint ink dot grid.
struct NeoDotBackground: View {
    var spacing: CGFloat = 22
    var dotSize: CGFloat = 2
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Neo.paper(scheme)
            Canvas { context, size in
                let color = scheme == .dark
                    ? Color.white.opacity(0.09)
                    : Color.black.opacity(0.14)
                let cols = Int(size.width / spacing) + 2
                let rows = Int(size.height / spacing) + 2
                for row in 0..<rows {
                    for col in 0..<cols {
                        let origin = CGPoint(
                            x: CGFloat(col) * spacing + spacing / 2,
                            y: CGFloat(row) * spacing + spacing / 2
                        )
                        let rect = CGRect(
                            x: origin.x, y: origin.y,
                            width: dotSize, height: dotSize
                        )
                        context.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Big heavy page title with a small uppercase accent sticker above it —
/// the in-content header from the neo-brutalist reference.
struct NeoPageHeader: View {
    var sticker: String
    var title: String
    var accent: Color = Neo.yellow
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sticker)
                .neoBadge(bg: accent)
            Text(title)
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(Neo.ink(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Neo rules & loading

/// 2pt ink rule replacing the system hairline `Divider`.
struct NeoDivider: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Neo.ink(scheme))
            .frame(height: 2)
    }
}

/// Indeterminate neo spinner: a bordered square with one filled quadrant.
struct NeoSpinner: View {
    var size: CGFloat = 16
    var fill: Color = Neo.yellow
    @Environment(\.colorScheme) private var scheme
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Rectangle().fill(Neo.paper(scheme))
            Rectangle()
                .fill(fill)
                .frame(width: size / 2, height: size / 2)
                .offset(x: -size / 4, y: -size / 4)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(2, size / 8), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: max(2, size / 8), style: .continuous)
                .stroke(Neo.ink(scheme), lineWidth: 2)
        )
        .rotationEffect(.degrees(angle))
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}

// MARK: - Neo menu picker

/// Neo-brutalist popup menu — replaces `.pickerStyle(.menu)` on macOS,
/// which cannot be themed.
struct NeoMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var bg: Color?
    var maxWidth: CGFloat?
    @Environment(\.colorScheme) private var scheme

    init(
        selection: Binding<Value>,
        options: [(value: Value, title: String)],
        bg: Color? = nil,
        maxWidth: CGFloat? = nil
    ) {
        _selection = selection
        self.options = options
        self.bg = bg
        self.maxWidth = maxWidth
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(currentTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .black))
            }
            .foregroundStyle(Neo.ink(scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(bg ?? Neo.paper(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Neo.ink(scheme), lineWidth: 2)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: maxWidth == nil, vertical: true)
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? "—"
    }
}

// MARK: - Formatting helpers

/// 1536 -> "1.5 KB", 2_147_483_648 -> "2.0 GB"
func formatBytes(_ bytes: Int64) -> String {
    let b = Double(bytes)
    guard b >= 1024 else { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var value = b / 1024
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
}

/// 1_048_576 -> "1.0 MB/s"
func formatSpeed(_ bytesPerSec: Double) -> String {
    "\(formatBytes(Int64(bytesPerSec)))/s"
}

/// 45 -> "45s", 900 -> "15m", 5400 -> "1h 30m", nil -> "—"
func formatETA(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
    let total = Int(seconds)
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

// MARK: - Directory picker

/// Presents an NSOpenPanel for choosing a directory. Returns nil on cancel.
func chooseDirectory(initial: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if let initial {
        panel.directoryURL = initial
    }
    return panel.runModal() == .OK ? panel.url : nil
}
