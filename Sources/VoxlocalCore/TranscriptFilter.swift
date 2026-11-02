import Foundation

/// Cleans up raw Whisper output before it is pasted.
public enum TranscriptFilter {
    /// Removes Whisper's non-speech markers such as `[BLANK_AUDIO]` or `(music)`, collapses
    /// whitespace, and returns nil when nothing meaningful is left.
    public static func clean(_ raw: String) -> String? {
        var text = raw
        // Whisper's special tokens, e.g. <|startoftranscript|>, in case any slip through.
        text = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        // Non-speech annotations: [BLANK_AUDIO], [Music], (silence), etc.
        text = text.replacingOccurrences(of: #"[\[(][^\])]{0,40}[\])]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
