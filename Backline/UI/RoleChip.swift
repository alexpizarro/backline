import BacklineKit
import SwiftUI

/// Who you are in the band (design plan 3.4): amber tape **YOU** + your part in Play and Beats,
/// **LISTEN** + the part up front in Dance.
///
/// Port of backline-ios Backline/UI/RoleChip.swift; the tape is drawn flat rather than on an iOS
/// capsule, and the menu replaces the Mac's old "I'm playing" pill row.
struct RoleChip: View {
    @Environment(AppModel.self) private var model

    private var dance: Bool { model.mode == .dance }

    /// The part name on the chip: your part, "2 parts" when several are off by hand, or "Nobody".
    private var partText: String {
        if dance {
            guard let k = model.settings.spotlight else { return "All" }
            return model.label(k)
        }
        let removed = model.settings.removed
        if let k = model.playingStem { return k.shortName }
        return removed.isEmpty ? "Full band" : "\(removed.count) parts"
    }

    private var choices: [StemKind] {
        if dance { return model.danceListenParts }
        return model.mainStems.filter { $0 != .other }
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            chipLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(dance ? "Listen for" : "Your part")
        .accessibilityValue(partText)
        .help(dance ? "Pick the part to listen for" : "Pick the part you play")
    }

    @ViewBuilder private var menuContent: some View {
        let s = model.settings
        let anythingOff = !s.removed.isEmpty || s.solo != nil || s.spotlight != nil
        Section(dance ? "Listen for" : "Your part") {
            ForEach(choices) { k in
                Button { pick(k) } label: {
                    Label(model.label(k), systemImage: s.spotlight == k || model.playingStem == k ? "checkmark" : k.symbol)
                }
            }
            Button { model.hearAll() } label: {
                Label("Full band", systemImage: anythingOff ? "person.3" : "checkmark")
            }
        }
        if !dance {
            Divider()
            Toggle(isOn: Binding(get: { model.settings.guide }, set: { model.settings.guide = $0 })) {
                Text("Guide")
                Text("Your part plays quietly")
            }
            .disabled(s.removed.isEmpty)
        }
        if anythingOff {
            Divider()
            Button { model.hearAll() } label: { Label("Hear all", systemImage: "speaker.wave.2") }
        }
    }

    private func pick(_ k: StemKind) {
        if dance { model.toggleSpotlight(k) } else { model.choosePlaying(k) }
    }

    private var chipLabel: some View {
        HStack(spacing: 6) {
            TapeTag(text: dance ? "LISTEN" : "YOU")
            Text(partText)
                .font(Typo.ui(12.5, .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.hairline2))
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// A small amber tape with black lettering: the chip's "YOU" / "LISTEN" label.
struct TapeTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typo.mono(9, .bold))
            .tracking(0.6)
            .foregroundStyle(Color.black.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(hex: 0xF5B94D)))
    }
}
