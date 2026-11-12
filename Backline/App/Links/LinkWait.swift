import Foundation
import Observation

/// The wait on the Getting-the-song screen before a link's audio arrives (L2): what the extractor is doing, whether
/// 15 s have gone by with nothing arriving ("Still trying. This can take a minute.", and Record instead beside
/// Cancel), and how many whole minutes the song service has been at it.
@MainActor @Observable
final class LinkWait {
    /// What the screen says while no audio has arrived.
    var stage: YouTubeExtractor.Stage = .connecting
    /// 15 s since the link was opened and nothing has arrived yet.
    private(set) var stillTrying = false
    /// Whole minutes the song service has been working on this song.
    private(set) var serviceMinutes = 0

    @ObservationIgnored let stillTryingAfter: Duration
    @ObservationIgnored let minute: Duration
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var serviceClock: Task<Void, Never>?

    init(stillTryingAfter: Duration = .seconds(15), minute: Duration = .seconds(60)) {
        self.stillTryingAfter = stillTryingAfter
        self.minute = minute
    }

    /// A link has started: the clock runs from now.
    func begin() {
        end()
        clock = Task { [weak self, stillTryingAfter] in
            try? await Task.sleep(for: stillTryingAfter)
            guard !Task.isCancelled else { return }
            self?.stillTrying = true
        }
    }

    /// The link's audio has arrived, it failed, or it was cancelled.
    func end() {
        clock?.cancel()
        clock = nil
        serviceEnded()
        stage = .connecting
        stillTrying = false
    }

    /// The song service has taken over: its own minutes count from here.
    func serviceBegan() {
        serviceClock?.cancel()
        serviceMinutes = 0
        serviceClock = Task { [weak self, minute] in
            while !Task.isCancelled {
                try? await Task.sleep(for: minute)
                guard !Task.isCancelled, let self else { return }
                self.serviceMinutes += 1
            }
        }
    }

    func serviceEnded() {
        serviceClock?.cancel()
        serviceClock = nil
        serviceMinutes = 0
    }
}
