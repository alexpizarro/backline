import BacklineKit
import SwiftUI

/// Settings ▸ Models (R01d): each downloadable model, what it does in one plain line, its size, whether it
/// is here, and who made it. Download Now and the player reminder live here. Ported from iOS
/// `UI/ModelsView.swift`; the Mac has no mobile-data switch.
struct ModelsView: View {
    @Environment(AppModel.self) private var model
    /// V02: off hides the extra parts row in the player. Download Now below stays, so turning the reminder
    /// off is not turning the models down.
    @AppStorage(ExtraParts.remindKey) private var remind = true

    /// The plain words for each model the app knows.
    struct Info {
        var title: String
        var line: String
        var credit: String
    }

    static func info(_ name: String) -> Info {
        switch name {
        case CleanerPartsJob.modelName:
            Info(title: "Cleaner parts", line: "Splits every song again, with less bleed between parts.",
                 credit: "BS-RoFormer SW, trained by jarredou.")
        case DrumSeparator.modelName:
            Info(title: "Drum parts", line: "Splits the drums into kick, snare, toms and hi-hats.",
                 credit: "MDX23C DrumSep by jarredou and aufr33. CC BY-NC-SA 4.0.")
        default:
            Info(title: name, line: "", credit: "")
        }
    }

    enum Status: Equatable {
        case ready, downloading(Int), notDownloaded, withdrawn

        var text: String {
            switch self {
            case .ready: "Ready"
            case .downloading(let p): "Downloading \(p)%"
            case .notDownloaded: "Not downloaded"
            case .withdrawn: "Not available right now"
            }
        }
    }

    static func status(_ asset: ModelAsset, installed: Bool, downloading: String?, progress: Double?, withdrawn: Set<String>) -> Status {
        if installed { return .ready }
        if downloading == asset.name { return .downloading(Int((progress ?? 0) * 100)) }
        if withdrawn.contains(asset.name) { return .withdrawn }
        return .notDownloaded
    }

    /// "344 MB"
    nonisolated static func size(_ bytes: Int64) -> String { "\(Int((Double(bytes) / 1_000_000).rounded())) MB" }

    /// "One-time 550 MB download.": the same round figure as the General tab and the player's row (as iOS).
    nonisolated static func downloadLine(_ bytes: Int64) -> String { "One-time \(AppModel.extraPartsSize(bytes)) download." }

    var body: some View {
        // Read so the list redraws when a download moves or ends (`missing` reads the disk).
        let downloading = model.downloadingModel
        let progress = model.modelDownloadProgress
        let missing = ModelDownloads.missing
        Form {
            Section {
                ForEach(ModelDownloads.assets, id: \.name) { asset in
                    row(asset, installed: !missing.contains { $0.name == asset.name }, downloading: downloading, progress: progress)
                }
            } footer: {
                Text("Downloaded from backlinestems.com or GitHub, and checked before use.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Remind me in the player", isOn: $remind)
                    .accessibilityIdentifier("models.remind")
                if !missing.isEmpty {
                    HStack {
                        Text(Self.downloadLine(missing.reduce(0) { $0 + $1.bytes }))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if downloading == nil {
                            Button("Download Now") { model.startModelDownloads(force: true) }
                                .accessibilityIdentifier("models.downloadNow")
                        } else {
                            Button("Cancel") { model.cancelModelDownloads() }
                                .accessibilityIdentifier("models.cancel")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ asset: ModelAsset, installed: Bool, downloading: String?, progress: Double?) -> some View {
        let info = Self.info(asset.name)
        let status = Self.status(asset, installed: installed, downloading: downloading,
                                 progress: progress, withdrawn: model.withdrawnModels)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.title).font(.body.weight(.semibold))
                Spacer()
                Text(Self.size(asset.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(info.line).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if status == .ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityHidden(true)
                }
                Text(status.text)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(status == .ready ? Theme.success : .secondary)
            }
            .padding(.top, 2)
            Text(info.credit).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("model.\(asset.name)")
    }
}
