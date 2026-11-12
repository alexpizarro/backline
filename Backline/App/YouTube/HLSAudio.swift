import Foundation

/// The fallback when a direct stream is refused: YouTube's audio-only HLS rendition (itag 234, AAC-LC
/// 128 kbps, a few seconds per segment). HLS isn't PO-token-gated. Segments are ADTS AAC with an ID3 tag
/// in front; they are joined into an m4a so `AVAudioFile` can read the result. Vimeo's rendition is
/// fragmented MP4 instead (an `#EXT-X-MAP` init segment, then fragments): those bytes are joined as they
/// are, which `AVAudioFile` reads directly.
nonisolated enum HLSAudio {
    struct Rendition: Equatable {
        var url: URL
        var itag: Int
        var score: Int
    }

    struct Playlist: Equatable {
        var segments: [URL]
        var duration: Double
        var isComplete: Bool
        /// Fragmented MP4: the init segment that goes in front of the fragments.
        var initSegment: URL?
        /// Segments addressed by byte range within one file (`#EXT-X-BYTERANGE`); not supported.
        var usesByteRanges = false
    }

    // MARK: Parsing (pure)

    /// `KEY=value,KEY="quoted, value"` → dictionary
    static func attributes(_ line: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        func commit() {
            if !key.isEmpty { result[key] = value }
            key = ""; value = ""; inKey = true
        }
        let body = line.drop { $0 != ":" }.dropFirst()
        for ch in body {
            if quoted {
                if ch == "\"" { quoted = false } else { value.append(ch) }
            } else if ch == "\"" {
                quoted = true
            } else if ch == "," {
                commit()
            } else if ch == "=" && inKey {
                inKey = false
            } else if inKey {
                key.append(ch)
            } else {
                value.append(ch)
            }
        }
        commit()
        return result
    }

    /// The audio renditions in a master playlist, best first.
    static func renditions(inMaster text: String, base: URL) -> [Rendition] {
        var found: [Rendition] = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXT-X-MEDIA") {
            let a = attributes(line)
            guard a["TYPE"] == "AUDIO", let uri = a["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            let itag = firstInt(after: "/itag/", in: uri) ?? 0
            var score: Int
            switch itag {
            case 234: score = 100
            case 233: score = 80
            default: score = 50
            }
            if a["DEFAULT"] == "YES" { score += 10 }
            if (a["NAME"] ?? "").lowercased().contains("descriptive") { score -= 50 }
            found.append(Rendition(url: url, itag: itag, score: score))
        }
        return found.sorted { $0.score > $1.score }
    }

    static func playlist(_ text: String, base: URL) -> Playlist {
        var segments: [URL] = []
        var duration = 0.0
        var complete = false
        var initSegment: URL?
        var byteRanges = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(Substring(line))
                initSegment = a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
                if a["BYTERANGE"] != nil { byteRanges = true }
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                byteRanges = true
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
                duration += Double(value) ?? 0
            } else if line == "#EXT-X-ENDLIST" {
                complete = true
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL {
                segments.append(url)
            }
        }
        return Playlist(segments: segments, duration: duration, isComplete: complete, initSegment: initSegment,
                        usesByteRanges: byteRanges)
    }

    private static func firstInt(after marker: String, in text: String) -> Int? {
        guard let r = text.range(of: marker) else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }

    // MARK: Download

    struct Output: Sendable {
        var seconds: Double
        var itag: Int
        var segments: Int
    }

    /// Fetches the best audio rendition of `manifest` into an m4a at `file`.
    static func download(manifest: URL, session: URLSession, userAgent: String, maxSeconds: Double, to file: URL,
                         progress: @escaping @Sendable (Double) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) async throws -> Output {
        let master = String(decoding: try await get(manifest, session, userAgent), as: UTF8.self)
        guard let rendition = renditions(inMaster: master, base: manifest).first else { throw RangedDownload.Failure.http(0) }
        let list = playlist(String(decoding: try await get(rendition.url, session, userAgent), as: UTF8.self), base: rendition.url)
        guard list.isComplete, !list.segments.isEmpty, !list.usesByteRanges else { throw RangedDownload.Failure.truncated }
        if list.duration > maxSeconds { throw TooLong() }

        // ADTS segments are rewrapped as an m4a; fragmented MP4 is kept byte for byte behind its init segment.
        let append: (Data) throws -> Void
        let finish: () throws -> Double
        let close: () -> Void
        if let initSegment = list.initSegment {
            let initData = try await get(initSegment, session, userAgent)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: initData)
            append = { try handle.write(contentsOf: $0) }
            finish = { try handle.synchronize(); return list.duration }
            close = { try? handle.close() }
        } else {
            let writer = try AACFileWriter(url: file)
            append = { try writer.append($0) }
            finish = { try writer.finish() }
            close = { writer.close() }
        }
        defer { close() }
        try await fetchInOrder(list.segments, window: window, fetch: { try await get($0, session, userAgent) },
                               append: append, progress: progress, isCancelled: isCancelled)
        let seconds = try finish()
        return Output(seconds: seconds, itag: rendition.itag, segments: list.segments.count)
    }

    struct TooLong: Error {}

    /// Segments in flight at once.
    static let window = 6

    /// Fetches `urls` with up to `window` requests in flight, starting the next as soon as any one finishes (a
    /// slow segment no longer holds up a whole batch, L10), and appends them strictly in order through a
    /// reorder buffer. Progress counts the segments appended.
    static func fetchInOrder(_ urls: [URL], window: Int, fetch: @escaping @Sendable (URL) async throws -> Data,
                             append: (Data) throws -> Void, progress: @Sendable (Double) -> Void,
                             isCancelled: @escaping @Sendable () -> Bool) async throws {
        guard !urls.isEmpty else { return }
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var started = 0
            var appended = 0
            var waiting = [Int: Data]()
            func startNext() {
                let index = started
                let url = urls[index]
                group.addTask { (index, try await fetch(url)) }
                started += 1
            }
            while started < min(max(window, 1), urls.count) { startNext() }
            while let (index, data) = try await group.next() {
                if Task.isCancelled || isCancelled() { group.cancelAll(); throw CancellationError() }
                waiting[index] = data
                while let ready = waiting.removeValue(forKey: appended) {
                    try append(ready)
                    appended += 1
                    progress(Double(appended) / Double(urls.count))
                }
                if started < urls.count { startNext() }
            }
        }
    }

    /// One GET with a couple of retries for dropped connections; 403 means this manifest has been refused.
    private static func get(_ url: URL, _ session: URLSession, _ userAgent: String) async throws -> Data {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw RangedDownload.Failure.http(0) }
                switch http.statusCode {
                case 200: return data
                case 403, 404, 410: throw RangedDownload.Failure.forbidden
                default: lastError = RangedDownload.Failure.http(http.statusCode)
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard RangedDownload.isTransient(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}
