import BacklineKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var windowDropTarget = false

    @State private var windowWidth: CGFloat = 1200

    /// The library hides itself when the window is too narrow to hold it comfortably.
    private var sidebarVisible: Bool { model.showSidebar && windowWidth >= WindowLimits.sidebarThreshold }

    var body: some View {
        @Bindable var model = model
        // GeometryReader reports the window's real width (the proposal), not the content's ideal width.
        GeometryReader { geo in
            HStack(spacing: 0) {
                if sidebarVisible {
                    LibrarySidebar()
                        .frame(width: WindowLimits.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.layoutWidth, LayoutWidth(width: geo.size.width - (sidebarVisible ? WindowLimits.sidebarWidth : 0)))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: geo.size.width, initial: true) { _, w in windowWidth = w }
        }
        .animation(.smooth(duration: 0.3), value: sidebarVisible)
        .background(Theme.bg)
        .overlay(alignment: .top) { TitleBar() }
        .overlay(alignment: .bottom) { ToastView() }
        .overlay {
            if windowDropTarget && model.screen == .mixer {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.primaryTint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.primary.opacity(0.08)))
                    .overlay(Text("Drop a song or YouTube link to split it").font(Typo.ui(15, .semibold)).foregroundStyle(Theme.ink))
                    .padding(12)
                    .padding(.top, 36)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $windowDropTarget) { providers in
            loadDropped(providers, model: model)
            return true
        }
        .sheet(isPresented: $model.exportSheet) { ExportSheet() }
        .sheet(isPresented: $model.recordSheet) { RecordFromAppSheet() }
        .sheet(isPresented: $model.showWelcome) { WelcomeSheet() }
        .sheet(isPresented: $model.addSongSheet) { AddSongSheet() }
        .sheet(isPresented: $model.youTubeSignInSheet) {
            YouTubeSignInSheet(onSignedIn: { if model.lastYouTube != nil, model.screen != .mixer { model.retryImport() } },
                               onSignedInIsRetry: model.lastYouTube != nil && model.screen != .mixer)
        }
        .background(WindowAccessor { model.mainWindow = $0 })
        .ignoresSafeArea()
        .containerBackground(Theme.bg, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.smooth(duration: 0.3), value: model.showSidebar)
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 44)
            switch model.screen {
            case .empty:
                EmptyStateView().transition(.opacity)
            case .analyzing:
                AnalyzingView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .mixer:
                MixerView().transition(.opacity)
            case .failed(let msg):
                FailureView(message: msg).transition(.opacity)
            }
        }
    }
}

/// Files open as songs; web links (e.g. dragged from a browser tab) open as YouTube imports.
func loadDropped(_ providers: [NSItemProvider], model: AppModel) {
    if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
        loadFirstURL(providers) { model.open($0) }
        return
    }
    guard let p = providers.first(where: { $0.canLoadObject(ofClass: URL.self) || $0.canLoadObject(ofClass: String.self) }) else { return }
    if p.canLoadObject(ofClass: URL.self) {
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in _ = model.openText(url.absoluteString) }
        }
    } else {
        _ = p.loadObject(ofClass: String.self) { s, _ in
            guard let s else { return }
            Task { @MainActor in _ = model.openText(s) }
        }
    }
}

func loadFirstURL(_ providers: [NSItemProvider], _ then: @escaping @MainActor (URL) -> Void) {
    guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return }
    _ = p.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in then(url) }
    }
}

/// Custom title bar area: centred title over the chrome colour, traffic lights provided by the system.
struct TitleBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.chrome.opacity(0.92))
                .background(.ultraThinMaterial)
            Text("Backline")
                .font(Typo.ui(13, .semibold))
                .foregroundStyle(Theme.ink2)
            HStack {
                Spacer().frame(width: 78)
                Button {
                    withAnimation(.smooth(duration: 0.3)) { model.showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.showSidebar ? "Hide library" : "Show library")
                Spacer()
            }
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Hands the hosting NSWindow to SwiftUI code (for the mini player's hide/restore).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
