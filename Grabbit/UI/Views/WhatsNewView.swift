import SwiftUI

/// "What's New" sheet shown once after the app updates: the release notes
/// bundled at build time, neo-styled like the rest of the app.
struct WhatsNewView: View {
    let digest: ReleaseNotes.Digest
    let version: String
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppIcon("sparkles", size: 20)
                    .font(.title3.weight(.bold))
                Text(NSLocalizedString("whatsnew.title", comment: ""))
                    .font(.title2.weight(.heavy))
                Spacer()
                Text("v\(version)")
                    .neoBadge(bg: Neo.yellow)
            }

            if !digest.title.isEmpty {
                Text(digest.title)
                    .font(.headline.weight(.bold))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(digest.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.headline.weight(.black))
                            Text(bullet)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(digest.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 340)

            HStack {
                Spacer()
                Button(NSLocalizedString("whatsnew.ok", comment: "")) {
                    dismiss()
                }
                .buttonStyle(NeoButtonStyle(bg: Neo.green))
            }
        }
        .padding(20)
        .frame(minWidth: 480, maxWidth: 580)
        .background(Neo.paper(scheme))
    }
}
