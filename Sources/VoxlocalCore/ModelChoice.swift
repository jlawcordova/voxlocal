import Foundation

/// The Whisper models offered in Settings, mapped to WhisperKit's Core ML variant names
/// in the `argmaxinc/whisperkit-coreml` repository.
public enum ModelChoice: String, CaseIterable, Codable, Sendable {
    case small
    case medium
    case largeV3Turbo = "large-v3-turbo"
    case largeV3 = "large-v3"

    public static let `default` = ModelChoice.largeV3Turbo

    public var variant: String {
        switch self {
        case .small: return "openai_whisper-small"
        case .medium: return "openai_whisper-medium"
        // OpenAI's Sept 2024 "turbo" release of large-v3 (4 decoder layers).
        case .largeV3Turbo: return "openai_whisper-large-v3-v20240930"
        case .largeV3: return "openai_whisper-large-v3"
        }
    }

    public var displayName: String {
        switch self {
        case .small: return "Small (fastest, ~500 MB)"
        case .medium: return "Medium (~1.5 GB)"
        case .largeV3Turbo: return "Large v3 Turbo (recommended, ~1.6 GB)"
        case .largeV3: return "Large v3 (most accurate, slowest, ~3 GB)"
        }
    }
}
