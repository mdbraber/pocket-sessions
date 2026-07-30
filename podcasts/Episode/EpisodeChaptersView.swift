import PocketCastsUtils
import SwiftUI

/// Fork: the episode screen's chapter list — timestamp, title, and tap to start playing there.
///
/// Collapsed to the first few rows by default: chapter lists routinely run to 20+ entries and the
/// show notes below them are what the screen is mostly for.
struct EpisodeChaptersView: View {
    @EnvironmentObject private var theme: Theme

    let chapters: [ChapterInfo]
    let onSelect: (ChapterInfo) -> Void

    @State private var expanded = false

    private static let collapsedCount = 5

    private var visibleChapters: [ChapterInfo] {
        expanded ? chapters : Array(chapters.prefix(Self.collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.chapters)
                .font(.headline)
                .foregroundStyle(AppTheme.color(for: .primaryText01, theme: theme))
                .padding(.bottom, 8)

            ForEach(visibleChapters, id: \.index) { chapter in
                Button {
                    onSelect(chapter)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(TimeFormatter.shared.playTimeFormat(time: chapter.startTime.seconds))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(AppTheme.color(for: .primaryText02, theme: theme))
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.color(for: .primaryText01, theme: theme))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            if chapters.count > Self.collapsedCount {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Text(expanded ? L10n.episodeChaptersShowLess : L10n.episodeChaptersShowAll)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppTheme.color(for: .primaryInteractive01, theme: theme))
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
