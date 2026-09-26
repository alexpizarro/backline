import BacklineKit
import SwiftUI

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var addHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)
            Text("Library")
                .font(Typo.ui(11, .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 18))

            if model.library.isEmpty {
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
                    ForEach(model.library) { rec in
                        LibraryRow(rec: rec, selected: rec.id == model.song?.id && model.screen == .mixer)
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
