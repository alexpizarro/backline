import BacklineKit
import SwiftUI

struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Namespace private var ns

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Text("Save a backing track")
                .font(Typo.ui(16, .bold))
                .foregroundStyle(Theme.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("File name").font(Typo.ui(12)).foregroundStyle(Theme.muted)
                HStack(spacing: 0) {
                    TextField("", text: $model.exportFileName)
                        .textFieldStyle(.plain)
                        .font(Typo.mono(12.5))
                        .foregroundStyle(Theme.ink)
                    Text(".\(model.exportFormat.fileExtension)")
                        .font(Typo.mono(12.5))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 11)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline2))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("File type").font(Typo.ui(12)).foregroundStyle(Theme.muted)
                HStack(spacing: 4) {
                    ForEach(ExportFormat.allCases) { f in
                        let sel = model.exportFormat == f
                        Button { model.exportFormat = f } label: {
                            Text(f.rawValue)
                                .font(Typo.ui(12.5, .semibold))
                                .foregroundStyle(sel ? .white : Theme.ink2)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background {
                                    if sel {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.primary)
                                            .matchedGeometryEffect(id: "fmt", in: ns)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.inset))
                .animation(.spring(duration: 0.28), value: model.exportFormat)
                Text(formatNote).font(Typo.ui(11)).foregroundStyle(Theme.muted)
            }

            if let r = model.loopRange {
                Toggle(isOn: $model.exportLoopOnly) {
                    Text("Only the loop (\(formatTime(r.lowerBound))–\(formatTime(r.upperBound)))")
                        .font(Typo.ui(12.5))
                        .foregroundStyle(Theme.ink2)
                }
                .toggleStyle(.checkbox)
                .tint(Theme.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Includes: \(included)")
                    .foregroundStyle(Theme.ink2)
                Text("Speed \(model.settings.speed)% · Pitch \(formatPitch(model.settings.pitch))")
                    .foregroundStyle(Theme.muted)
            }
            .font(Typo.ui(12.5))
            .lineSpacing(3)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.exportSheet = false }
                    .buttonStyle(SecondaryButtonStyle(padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.performExport() }
                    .buttonStyle(PrimaryButtonStyle(padding: EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.audibleStems.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.card)
        .preferredColorScheme(.dark)
    }

    var included: String {
        let names = model.audibleStems.map(\.name)
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }

    var formatNote: String {
        switch model.exportFormat {
        case .wav: "Best sound · works everywhere"
        case .aiff: "Best sound · for GarageBand and Logic"
        case .mp3: "Good sound · smallest file"
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.isExporting {
                HStack(spacing: 10) {
                    ProgressView(value: model.exportProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Theme.primaryTint)
                    Text("Saving… \(Int(model.exportProgress * 100))%")
                        .font(Typo.ui(13))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
                .toastChrome()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let t = model.toast {
                HStack(spacing: 8) {
                    Circle().fill(t.isError ? Theme.danger : Theme.success).frame(width: 8, height: 8)
                    Text(t.text).font(Typo.ui(13)).foregroundStyle(Theme.ink)
                    if let url = t.url {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.plain)
                            .font(Typo.ui(13, .semibold))
                            .foregroundStyle(Theme.primaryTint)
                            .padding(.leading, 6)
                    }
                }
                .toastChrome()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
            }
        }
        .padding(.bottom, 84)
        .animation(.spring(duration: 0.35), value: model.isExporting)
    }
}

extension View {
    func toastChrome() -> some View {
        padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardHover.opacity(0.92)))
            .glassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), fallback: Theme.cardHover)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline3))
            .shadow(color: .black.opacity(0.4), radius: 15, y: 10)
    }
}
