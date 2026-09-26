import Foundation
import Testing
@testable import BacklineKit

/// Keeps the built-in help at a 5th-grade reading level (Flesch-Kincaid grade ≤ 5 per page) with short
/// sentences, so it stays readable for someone with no technical background.
struct HelpContentTests {
    @Test func everyTopicHasAPage() {
        for t in HelpTopic.allCases { #expect(HelpContent.pages.contains { $0.topic == t }, "missing \(t)") }
    }

    @Test func readingLevelIsFifthGradeOrBelow() {
        for page in HelpContent.pages {
            let text = ([page.intro] + page.steps.map(\.text) + [page.tip].compactMap { $0 }).joined(separator: " ")
            let grade = Readability.fleschKincaidGrade(text)
            #expect(grade <= 5.0, "\(page.title): grade \(String(format: "%.1f", grade))")
            for s in Readability.sentences(text) {
                #expect(Readability.words(s).count <= 22, "long sentence in \(page.title): \(s)")
            }
        }
    }
}

enum Readability {
    static func sentences(_ t: String) -> [String] {
        t.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func words(_ t: String) -> [String] {
        t.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
    /// Standard vowel-group syllable estimate (silent trailing e, minimum one).
    static func syllables(_ w: String) -> Int {
        let word = w.lowercased().filter(\.isLetter)
        guard !word.isEmpty else { return 0 }
        if word.count <= 3 { return 1 }
        var count = 0, prevVowel = false
        for ch in word {
            let v = "aeiouy".contains(ch)
            if v && !prevVowel { count += 1 }
            prevVowel = v
        }
        if word.hasSuffix("e") && !word.hasSuffix("le") && count > 1 { count -= 1 }
        return max(1, count)
    }
    static func fleschKincaidGrade(_ t: String) -> Double {
        let s = max(1, sentences(t).count)
        let w = words(t)
        let syl = w.reduce(0) { $0 + syllables($1) }
        return 0.39 * Double(w.count) / Double(s) + 11.8 * Double(syl) / Double(max(1, w.count)) - 15.59
    }
}
