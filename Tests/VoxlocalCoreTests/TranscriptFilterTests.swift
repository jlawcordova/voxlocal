import Testing
@testable import VoxlocalCore

@Suite struct TranscriptFilterTests {
    @Test func stripsNonSpeechMarkers() {
        #expect(TranscriptFilter.clean(" [BLANK_AUDIO] ") == nil)
        #expect(TranscriptFilter.clean("(music)  Kumusta ka,  how are you?") == "Kumusta ka, how are you?")
    }

    @Test func keepsMixedLanguageText() {
        #expect(TranscriptFilter.clean("Maayong buntag, let's go na.") == "Maayong buntag, let's go na.")
    }
}
