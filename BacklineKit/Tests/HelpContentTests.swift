import Foundation
import Testing
@testable import BacklineKit

/// Keeps the built-in help at a 5th-grade reading level (Flesch-Kincaid grade ≤ 5 per page) with short
/// sentences, so it stays readable for someone with no technical background.
struct HelpContentTests {
    /// Both page sets, whatever platform the tests run on.
    static let sets: [(name: String, pages: [HelpPage])] = [("touch", HelpContent.touchPages), ("Mac", HelpContent.macPages)]

    @Test func everyTopicHasAPage() {
        for (name, pages) in Self.sets {
            for t in HelpTopic.allCases { #expect(pages.filter { $0.topic == t }.count == 1, "\(name): \(t)") }
        }
    }

    /// The app shows the set written for it.
    @Test func theAppShowsItsOwnSet() {
        #if os(macOS)
        #expect(HelpContent.pages.map(\.title) == HelpContent.macPages.map(\.title))
        #expect(HelpContent.page(.start).steps.map(\.text) == HelpContent.macPages[0].steps.map(\.text))
        #else
        #expect(HelpContent.pages.map(\.title) == HelpContent.touchPages.map(\.title))
        #endif
    }

    /// Both sets list the topics in the same order, so Help reads the same on every device.
    @Test func bothSetsHaveTheSameOrder() {
        #expect(HelpContent.macPages.map(\.topic) == HelpContent.touchPages.map(\.topic))
    }

    /// Design plan 3.11: every page starts with one sentence.
    @Test func everyIntroIsOneSentence() {
        for (_, pages) in Self.sets {
            for page in pages {
                #expect(Readability.sentences(page.intro).count == 1, "\(page.title): \(page.intro)")
            }
        }
    }

    /// The help never names a site a song comes from (release plan, Decision 2).
    @Test func noSiteIsNamed() {
        for (name, pages) in Self.sets {
            for page in pages {
                #expect(!Self.text(page).localizedCaseInsensitiveContains("youtube"), "\(name): \(page.title)")
            }
        }
    }

    /// The Mac pages speak to a Mac: nobody taps, swipes or locks a phone there. "Tap on the 1" is the
    /// name of a button, so it is the one place the word may appear.
    @Test func macPagesHaveNoTouchWords() {
        for page in HelpContent.macPages {
            let text = Self.text(page).replacingOccurrences(of: "Tap on the 1", with: "")
            let words = Set(Readability.words(text).map { $0.lowercased() })
            for banned in ["tap", "taps", "tapped", "swipe", "phone", "iphone", "ipad", "pinch", "touch"] {
                #expect(!words.contains(banned), "\(page.title) says \"\(banned)\"")
            }
            #expect(!text.localizedCaseInsensitiveContains("lock screen"), "\(page.title)")
            #expect(!text.localizedCaseInsensitiveContains("share"), "\(page.title): the Mac has no Share to Backline")
        }
    }

    /// The touch pages never send someone to a Mac menu or key ("click" is also the metronome there).
    @Test func touchPagesHaveNoMacWords() {
        for page in HelpContent.touchPages {
            let words = Set(Readability.words(Self.text(page)).map { $0.lowercased() })
            for banned in ["finder", "command", "mac"] {
                #expect(!words.contains(banned), "\(page.title) says \"\(banned)\"")
            }
            #expect(!Self.text(page).localizedCaseInsensitiveContains("right-click"), "\(page.title)")
        }
    }

    @Test func readingLevelIsFifthGradeOrBelow() {
        for (name, pages) in Self.sets {
            for page in pages {
                let text = ([page.intro] + page.steps.map(\.text) + [page.tip].compactMap { $0 }).joined(separator: " ")
                let grade = Readability.fleschKincaidGrade(text)
                #expect(grade <= 5.0, "\(name) \(page.title): grade \(String(format: "%.1f", grade))")
                for s in Readability.sentences(text) {
                    #expect(Readability.words(s).count <= 22, "long sentence in \(name) \(page.title): \(s)")
                }
            }
        }
    }

    static func text(_ page: HelpPage) -> String {
        ([page.title, page.intro] + page.steps.map(\.text) + [page.tip].compactMap { $0 }).joined(separator: " ")
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
