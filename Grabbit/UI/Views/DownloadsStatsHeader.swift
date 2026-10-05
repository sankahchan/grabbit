import SwiftUI

// MARK: - Dot-matrix digits

/// 5×7 flip-dot numeral renderer (the reference's dot display). Digits,
/// "." and "+" are supported; unknown characters are skipped.
struct DotMatrixDigits: View {
    let text: String
    var color: Color
    var dot: CGFloat = 2.5
    var spacing: CGFloat = 1.45

    private static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        ".": ["00000", "00000", "00000", "00000", "00000", "00000", "00100"],
        "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
        "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    ]

    private var pitch: CGFloat { dot + spacing }
    private var glyphWidth: CGFloat { 5 * pitch - spacing }
    private var characterGap: CGFloat { pitch * 1.3 }

    private var drawnCount: Int {
        text.filter { Self.glyphs[$0] != nil }.count
    }

    private var width: CGFloat {
        guard drawnCount > 0 else { return 0 }
        return CGFloat(drawnCount) * glyphWidth
            + CGFloat(drawnCount - 1) * characterGap
    }

    private var height: CGFloat { 7 * pitch - spacing }

    var body: some View {
        Canvas { context, _ in
            var x: CGFloat = 0
            for character in text {
                guard let rows = Self.glyphs[character] else { continue }
                for (rowIndex, row) in rows.enumerated() {
                    for (columnIndex, bit) in row.enumerated() where bit == "1" {
                        let rect = CGRect(
                            x: x + CGFloat(columnIndex) * pitch,
                            y: CGFloat(rowIndex) * pitch,
                            width: dot, height: dot)
                        context.fill(
                            Path(ellipseIn: rect), with: .color(color))
                    }
                }
                x += glyphWidth + characterGap
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Mini bar chart

/// Tiny bottom-aligned bar chart for the stat cards. Empty slots render as
/// faint stubs so the card keeps the reference's instrument-panel rhythm.
struct MiniBarChart: View {
    var values: [Double]
    var slots: Int
    var accent: Color
    var height: CGFloat = 18
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let recent = Array(values.suffix(slots))
        let padded = [Double](repeating: -1, count: max(0, slots - recent.count))
            + recent
        let peak = max(recent.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fill(for: value, peak: peak))
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight(for: value, peak: peak))
            }
        }
        .frame(height: height)
    }

    private func fill(for value: Double, peak: Double) -> Color {
        guard value > 0 else { return Neo.ink(scheme).opacity(0.07) }
        return accent.opacity(0.50 + 0.50 * min(1, value / peak))
    }

    private func barHeight(for value: Double, peak: Double) -> CGFloat {
        guard value > 0 else { return 4 }
        return max(5, height * CGFloat(min(1, value / peak)))
    }
}

// MARK: - Stat card

/// One dashboard card: small-caps label, dot-matrix value + unit, live
/// subtitle and the mini chart. `neoCard(accent:)` gives it the edge-lit
/// treatment automatically on themes that use it (Pulse).
struct DownloadsStatCard: View {
    let label: String
    let value: String
    let unit: String?
    let subtitle: String
    let accent: Color
    let chart: MiniBarChart
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(NeoFont.f(9, .bold))
                    .tracking(1.2)
                    .foregroundStyle(Neo.ink2(scheme))
                Spacer()
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: accent.opacity(0.8), radius: 3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                DotMatrixDigits(text: value, color: accent)
                if let unit {
                    Text(unit)
                        .font(NeoFont.f(.caption2, .semibold))
                        .foregroundStyle(Neo.ink2(scheme))
                }
            }
            Text(subtitle)
                .font(NeoFont.f(.caption))
                .foregroundStyle(Neo.ink2(scheme))
                .lineLimit(1)
            // No Spacer: a flexible card would stretch with the window
            // (chart pinned to the bottom, empty middle). Content-sized.
            chart
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .neoCard(accent: accent.opacity(0.75), inset: 10)
    }
}

// MARK: - Sort order

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all
    case downloading
    case paused
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: NSLocalizedString("downloads.filter.all", comment: "")
        case .downloading: NSLocalizedString("downloads.filter.downloading", comment: "")
        case .paused: NSLocalizedString("downloads.filter.paused", comment: "")
        case .failed: NSLocalizedString("downloads.filter.failed", comment: "")
        }
    }

    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .downloading: item.state == .downloading
        case .paused: item.state == .paused || item.state == .queued
        case .failed: item.state == .failed
        }
    }
}

enum DownloadSortOrder: String, CaseIterable, Identifiable {
    case added
    case name
    case progress
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .added: NSLocalizedString("downloads.sort.added", comment: "")
        case .name: NSLocalizedString("downloads.sort.name", comment: "")
        case .progress: NSLocalizedString("downloads.sort.progress", comment: "")
        case .size: NSLocalizedString("downloads.sort.size", comment: "")
        }
    }
}
