import BacklineKit
import SwiftUI

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var addHover = false
    /// Search appears once there are 8 songs or more, as on iOS (`LibraryView`).
    @State private var query = ""

    static let searchFrom = 8

    /// The songs whose title or artist contains the words typed, ignoring case.
    nonisolated static func filter(_ songs: [SongRecord], query: String) -> [SongRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return songs }
        return songs.filter { $0.title.lowercased().contains(q) || ($0.artist ?? "").lowercased().contains(q) }
    }

    /// "Songs you split appear here…" only while the Library is empty and nothing is being split: the first
    /// song's importing row says it already.
    nonisolated static func showsEmptyLine(libraryIsEmpty: Bool, importing: Bool) -> Bool { libraryIsEmpty && !importing }

    private var songs: [SongRecord] {
        model.library.count >= Self.searchFrom ? Self.filter(model.library, query: query) : model.library
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)
            Text("Library")
                .font(Typo.ui(11, .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 18))

            if model.library.count >= Self.searchFrom {
                LibrarySearchField(text: $query)
                    .padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
            }

            if Self.showsEmptyLine(libraryIsEmpty: model.libraryIsEmpty, importing: model.screen == .analyzing) {
                Text("Songs you split appear here and reopen instantly.")
                    .font(Typo.ui(12))
                    .foregroundStyle(Theme.muted.opacity(0.8))
                    .padding(.horizontal, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: 2) {
                    if model.screen == .analyzing {
                        ImportingRow(title: model.importTitle, fraction: model.importProgress.fraction)
                    }
                    ForEach(model.unfinishedImports) { u in
                        UnfinishedRow(item: u)
                    }
                    ForEach(songs) { rec in
                        LibraryRow(rec: rec, selected: rec.id == model.song?.id && model.screen == .mixer)
                    }
                    if songs.isEmpty, !model.library.isEmpty {
                        Text("No songs match.")
                            .font(Typo.ui(12))
                            .foregroundStyle(Theme.muted)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            Button { model.addSong() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primaryTint)
                    Text("Add song").font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink2)
                    Spacer()
                    Text("⌘O").font(Typo.mono(10.5)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(addHover ? Theme.card : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { addHover = $0 }
            .padding(10)
            .padding(.bottom, 6)
        }
        .background(Theme.chrome)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
    }
}

/// The Library's search field: the title or artist, as you type.
struct LibrarySearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.ui(12.5))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
                .accessibilityIdentifier("library.search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Theme.primaryTint.opacity(0.6) : Theme.hairline2))
    }
}

struct LibraryRow: View {
    @Environment(AppModel.self) private var model
    let rec: SongRecord
    let selected: Bool
    @State private var hover = false
    @State private var confirmDelete = false

    var body: some View {
        Button { model.select(rec) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title)
                    .font(Typo.ui(13, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(rec.artist ?? subtitle).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(rec.durationString).font(Typo.mono(11.5))
                }
                .font(Typo.ui(11.5))
                .foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.cardHover : (hover ? Theme.card.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.store.folder(rec.id)])
            }
            Divider()
            Button("Remove from Library…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Remove “\(rec.title)” from the library?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { model.remove(rec) }
        } message: {
            Text("Backline deletes the split parts. Your own song file stays safe.")
        }
    }

    var subtitle: String {
        let removed = rec.settings.removed.map(\.name).sorted()
        return removed.isEmpty ? "Full band" : "No " + removed.joined(separator: ", ").lowercased()
    }
}

struct ImportingRow: View {
    let title: String
    let fraction: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typo.ui(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            ProgressTrack(fraction: fraction).frame(height: 3)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card.opacity(0.6)))
    }
}

/// An import the last run ended during (D20 d): the song's name, what happened in one line, and the way
/// forward in the failure screen's words ("Try again", and "Remove" for what Backline kept). Trying again, or
/// clicking the song itself (R3), splits the file again from where its split stopped; nothing is downloaded
/// again. Ported from iOS `UnfinishedRow`, sized for the sidebar.
struct UnfinishedRow: View {
    @Environment(AppModel.self) private var model
    let item: WorkJournal.Unfinished

    var body: some View {
        let canRetry = AppModel.mayTryAgain(item)
        VStack(alignment: .leading, spacing: 8) {
            if canRetry {
                Button { model.retryUnfinished(item) } label: { summary }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("unfinished.\(item.id)")
                    .accessibilityHint("Carries on splitting it")
                    .help("Carry on splitting this song")
            } else {
                summary
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("unfinished.\(item.id)")
            }
            HStack(spacing: 6) {
                if canRetry {
                    Button("Try again") { model.retryUnfinished(item) }
                        .buttonStyle(PrimaryButtonStyle(padding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)))
                }
                Button("Remove") { model.removeUnfinished(item) }
                    .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)))
                Spacer(minLength: 0)
            }
            .padding(.leading, 19)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card.opacity(0.6)))
    }

    /// The song's name and what happened.
    private var summary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.title.isEmpty ? "Song not finished" : item.entry.title)
                    .font(Typo.ui(13, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(AppModel.unfinishedLine(item))
                    .font(Typo.ui(11.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
