import Foundation

/// D20 (c): when the system says memory is short, the background passes stop and their models go with them;
/// playing and an import carry on. The passes start again once memory has had a minute to come back. Ported
/// from iOS `AppModel+Memory.swift`; a Mac has no app memory warning, so the system's memory-pressure source
/// is the one signal.
enum MemoryWatch {
    /// The system's memory-pressure source, kept for the app's life.
    static var source: DispatchSourceMemoryPressure?
    /// The pending restart of the passes after a memory stop.
    static var retry: Task<Void, Never>?
}

extension AppModel {
    /// Listens for the system's memory-pressure warnings and for the passes' own memory stops.
    func watchMemory() {
        if MemoryWatch.source == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                let critical = source?.data.contains(.critical) == true
                MainActor.assumeIsolated { self?.memoryPressure(critical: critical) }
            }
            source.activate()
            MemoryWatch.source = source
        }
        NotificationCenter.default.addObserver(forName: MemoryBudget.shortNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryPassesAfterMemoryStop() }
        }
    }

    /// The system's memory pressure, which on a Mac is the whole system's, not Backline's. A warning is only
    /// written down: the passes check their own room before each chunk, and stopping them on every warning could
    /// stop and restart them for ever on an 8 GB Mac (each now carries on from its checkpoint, but loses its
    /// current chunk and its model load). Critical pressure stops them (K1 on iOS: a warning with room left stops
    /// nothing there either).
    func memoryPressure(critical: Bool) {
        if critical { memoryWarning("pressure critical"); return }
        AppLog.note("memory: pressure warning, \(MemoryFootprint.megabytes) MB held; background passes go on")
    }

    /// Memory is short: the passes stop (each frees its model as it unwinds) and none starts for a minute.
    /// Nothing that plays is touched, and an import goes on.
    func memoryWarning(_ level: String) {
        let running = [leadJob, drumJob, hqJob, compactJob].compactMap { $0 }.count
        MemoryBudget.noteShort("\(level): \(MemoryFootprint.megabytes) MB held, "
                               + (running > 0 ? "background passes stopped" : "no background pass running"))
        if running > 0 { pauseBackgroundWork() }
    }

    /// After a memory stop, the open song's passes start again once the minute is up.
    func retryPassesAfterMemoryStop() {
        guard MemoryWatch.retry == nil else { return }
        MemoryWatch.retry = Task { [weak self] in
            repeat {
                try? await Task.sleep(for: .seconds(MemoryBudget.backoff + 1))
            } while !MemoryBudget.mayStartPass && !Task.isCancelled
            MemoryWatch.retry = nil
            guard let self, !self.resetting, !Task.isCancelled else { return }
            AppLog.note("memory: starting the background passes again")
            self.ensureLeadRefine()
            self.ensureCleanerParts()
            self.ensureDrumSplit()
            self.ensurePartsCompact()
            self.ensureLibraryLeadRefine()
        }
    }

    /// ios-import#4: `pass` of song `id` was refused at its start for want of room. It isn't started again by
    /// itself until the song is next opened or the app next comes to the front.
    func noteRoomRefused(_ pass: MemoryBudget.Pass, _ id: String) {
        roomRefused[id, default: []].insert(pass)
    }

    func isRoomRefused(_ pass: MemoryBudget.Pass, _ id: String) -> Bool {
        roomRefused[id]?.contains(pass) == true
    }
}
