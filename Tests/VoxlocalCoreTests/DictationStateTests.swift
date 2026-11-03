import Testing
@testable import VoxlocalCore

@MainActor
@Suite struct DictationStateTests {
    typealias Phase = DictationState.Phase

    @Test func happyPathWithCleanup() {
        let s = DictationState()
        #expect(s.startListening())
        #expect(s.beginTranscribing())
        #expect(s.beginPolishing())
        #expect(s.finishPasted(raw: false))
        #expect(s.phase == .pasted(raw: false))
    }

    @Test func cleanupOffSkipsPolishing() {
        let s = DictationState()
        s.startListening()
        s.beginTranscribing()
        #expect(s.finishPasted(raw: false))
    }

    @Test func cleanupFallbackIsPastedRawNotError() {
        let s = DictationState()
        s.startListening(); s.beginTranscribing(); s.beginPolishing()
        #expect(s.finishPasted(raw: true))
        #expect(s.phase == .pasted(raw: true))
    }

    @Test func invalidTransitionsAreIgnored() {
        let s = DictationState()
        #expect(!s.beginTranscribing())
        #expect(!s.beginPolishing())
        #expect(!s.finishPasted(raw: false))
        #expect(s.phase == .idle)

        s.startListening()
        #expect(!s.beginPolishing())          // must transcribe first
        #expect(!s.finishPasted(raw: false))  // nothing to paste yet
        #expect(!s.startListening())          // already listening
        #expect(s.phase == .listening)
    }

    @Test func transitionTable() {
        let allowed: [(Phase, Phase)] = [
            (.idle, .listening), (.listening, .transcribing), (.transcribing, .polishing),
            (.transcribing, .pasted(raw: false)), (.polishing, .pasted(raw: true)),
            (.listening, .idle), (.transcribing, .idle), (.pasted(raw: false), .idle), (.error("x"), .idle),
            (.polishing, .error("x")), (.pasted(raw: false), .listening), (.error("x"), .listening),
        ]
        for (from, to) in allowed {
            #expect(DictationState.canTransition(from: from, to: to), "\(from) → \(to)")
        }
        let denied: [(Phase, Phase)] = [
            (.idle, .transcribing), (.idle, .polishing), (.idle, .pasted(raw: false)),
            (.listening, .polishing), (.polishing, .listening), (.polishing, .idle),
            (.pasted(raw: false), .polishing), (.transcribing, .listening),
        ]
        for (from, to) in denied {
            #expect(!DictationState.canTransition(from: from, to: to), "\(from) → \(to)")
        }
    }

    @Test func pastedAndErrorReturnToIdle() async throws {
        let s = DictationState(pastedDuration: .milliseconds(30), errorDuration: .milliseconds(30))
        s.startListening(); s.beginTranscribing(); s.finishPasted(raw: false)
        try await Task.sleep(for: .milliseconds(120))
        #expect(s.phase == .idle)

        s.startListening(); s.fail("Microphone unavailable")
        #expect(s.phase == .error("Microphone unavailable"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(s.phase == .idle)
    }

    @Test func staleAutoReturnDoesNotInterruptNewDictation() async throws {
        let s = DictationState(pastedDuration: .milliseconds(40))
        s.startListening(); s.beginTranscribing(); s.finishPasted(raw: false)
        s.startListening()  // user starts again before the checkmark fades
        try await Task.sleep(for: .milliseconds(120))
        #expect(s.phase == .listening)
    }

    @Test func levelOnlyAppliesWhileListening() {
        let s = DictationState()
        s.updateLevel(0.5)
        #expect(s.level == 0)
        s.startListening()
        s.updateLevel(1.7)
        #expect(s.level == 1)
        s.cancel()
        s.startListening()
        #expect(s.level == 0)
    }

    @Test func liveTextArrivesWhileListeningAndCarriesIntoTranscribing() {
        let s = DictationState()
        s.updatePartial("ignored while idle")
        #expect(s.partialText == "")

        s.startListening()
        s.updatePartial("  Kumusta ka  ")
        #expect(s.partialText == "Kumusta ka")

        // No flicker: the live text stays up while the final pass runs.
        s.beginTranscribing()
        #expect(s.partialText == "Kumusta ka")
        s.updatePartial("Kumusta ka na?")
        #expect(s.partialText == "Kumusta ka na?")

        // Ignored once polishing; cleared when the next dictation starts.
        s.beginPolishing()
        s.updatePartial("late update")
        #expect(s.partialText == "Kumusta ka na?")
        s.finishPasted(raw: false)
        s.startListening()
        #expect(s.partialText == "")
    }

    @Test func liveTextSplitsOffTheLastFewWords() {
        let parts = DictationState.liveParts("I was thinking na mag-lunch tayo sa Davao")
        #expect(parts.settled == "I was thinking na mag-lunch")
        #expect(parts.tentative == "tayo sa Davao")

        let short = DictationState.liveParts("Kumusta ka")
        #expect(short.settled == "")
        #expect(short.tentative == "Kumusta ka")

        #expect(DictationState.liveParts("").tentative == "")
    }

    @Test func tailKeepsTheNewestWords() {
        #expect(DictationState.tail("short") == "short")
        let long = String(repeating: "a", count: 50) + " the newest words are here"
        let t = DictationState.tail(long, limit: 20)
        #expect(t.hasPrefix("…"))
        #expect(t.hasSuffix("the newest words are here".suffix(15)))
        #expect(t.count <= 21)
    }
}
