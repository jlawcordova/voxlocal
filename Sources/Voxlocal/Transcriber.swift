import Foundation
import VoxlocalCore
import WhisperKit

/// Owns the on-device Whisper model. The model is downloaded once from Hugging Face into
/// ~/Library/Application Support/Voxlocal/Models; after that it is loaded with downloads
/// disabled, so transcription never touches the network.
actor Transcriber {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private var whisper: WhisperKit?
    private var loadedModel: ModelChoice?

    static let modelsRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Voxlocal/Models", isDirectory: true)
    }()

    /// Where WhisperKit's Hub client lays out a downloaded variant.
    static func modelFolder(for model: ModelChoice) -> URL {
        modelsRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)", isDirectory: true)
    }

    /// The tokenizer comes from the matching openai/whisper-* repo and is fetched with the model.
    static func tokenizerFile(for model: ModelChoice) -> URL {
        let repo = model == .small ? "whisper-small" : model == .medium ? "whisper-medium" : "whisper-large-v3"
        return modelsRoot.appendingPathComponent("models/openai/\(repo)/tokenizer.json")
    }

    static func isDownloaded(_ model: ModelChoice) -> Bool {
        let fm = FileManager.default
        let folder = modelFolder(for: model)
        return fm.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
            && fm.fileExists(atPath: tokenizerFile(for: model).path)
    }

    func prepare(_ model: ModelChoice, progress: @escaping @Sendable (Phase) -> Void) async {
        if loadedModel == model, whisper != nil {
            progress(.ready)
            return
        }
        whisper = nil
        loadedModel = nil
        do {
            try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
            let alreadyLocal = Self.isDownloaded(model)
            if !alreadyLocal {
                // The one-time network step: fetch the Core ML model from Hugging Face.
                progress(.downloading(0))
                _ = try await WhisperKit.download(variant: model.variant, downloadBase: Self.modelsRoot) { p in
                    progress(.downloading(p.fractionCompleted))
                }
            }
            progress(.loading)
            let config = WhisperKitConfig(
                model: model.variant,
                downloadBase: Self.modelsRoot,
                modelFolder: Self.modelFolder(for: model).path,
                tokenizerFolder: Self.modelsRoot,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            )
            // On a fresh download the tokenizer is fetched here, once; later loads find it locally.
            whisper = try await WhisperKit(config)
            loadedModel = model
            progress(.ready)
        } catch {
            progress(.failed(error.localizedDescription))
        }
    }

    /// Transcribes 16 kHz mono samples. Language is detected per recording.
    func transcribe(_ samples: [Float]) async throws -> String? {
        guard let whisper else { throw TranscriberError.notReady }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return TranscriptFilter.clean(text)
    }

    enum TranscriberError: LocalizedError {
        case notReady
        var errorDescription: String? { "The speech model isn't loaded yet." }
    }
}
