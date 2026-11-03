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
    private var previewTask: Task<[TranscriptionResult]?, Never>?
    private let stopPreview = StopFlag()
    private var loadedModel: ModelChoice?
    /// The most recently requested model; an older, slower load that finishes later is dropped.
    private var requestedModel: ModelChoice?

    static let modelsRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Voxlocal/Models", isDirectory: true)
    }()

    /// Where WhisperKit's Hub client lays out a downloaded variant.
    static func modelFolder(for model: ModelChoice) -> URL {
        modelsRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.variant)", isDirectory: true)
    }

    /// The tokenizer usually ships inside the model folder; older variants fetch it from the
    /// matching openai/whisper-* repo instead.
    static func tokenizerFiles(for model: ModelChoice) -> [URL] {
        let repo = model == .small ? "whisper-small" : model == .medium ? "whisper-medium" : "whisper-large-v3"
        return [
            modelFolder(for: model).appendingPathComponent("tokenizer.json"),
            modelsRoot.appendingPathComponent("models/openai/\(repo)/tokenizer.json"),
        ]
    }

    static func isDownloaded(_ model: ModelChoice) -> Bool {
        let fm = FileManager.default
        let folder = modelFolder(for: model)
        return fm.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
            && tokenizerFiles(for: model).contains { fm.fileExists(atPath: $0.path) }
    }

    static func downloadedModels() -> Set<ModelChoice> {
        Set(ModelChoice.allCases.filter(isDownloaded))
    }

    /// Bytes the model's folder takes on disk.
    static func diskSize(of model: ModelChoice) -> Int64 {
        let folder = modelFolder(for: model)
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Removes a downloaded model from disk. The loaded model can't be deleted.
    func delete(_ model: ModelChoice) throws {
        guard model != loadedModel else { throw TranscriberError.modelInUse }
        let folder = Self.modelFolder(for: model)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func prepare(_ model: ModelChoice, progress: @escaping @Sendable (Phase) -> Void) async {
        if loadedModel == model, whisper != nil {
            progress(.ready)
            return
        }
        requestedModel = model
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
            let loaded = try await WhisperKit(config)
            guard requestedModel == model else { return }
            whisper = loaded
            loadedModel = model
            progress(.ready)
        } catch {
            progress(.failed(error.localizedDescription))
        }
    }

    /// Transcribes 16 kHz mono samples. Language is detected per recording.
    /// A quick, display-only pass over audio recorded so far, while the user is still speaking.
    /// Skipped if a preview is already running; stopped early if the final pass starts.
    /// `language` pins the language once it has been detected from enough audio.
    func preview(_ samples: [Float], language: String?) async -> (text: String, language: String)? {
        guard let whisper, previewTask == nil else { return nil }
        stopPreview.set(false)
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let stop = stopPreview
        let task = Task<[TranscriptionResult]?, Never> {
            try? await whisper.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in
                stop.isSet ? false : nil
            })
        }
        previewTask = task
        let results = await task.value
        previewTask = nil
        guard !stopPreview.isSet, let results, let first = results.first else { return nil }
        let text = TranscriptFilter.clean(results.map(\.text).joined(separator: " ")) ?? ""
        return (text, first.language)
    }

    /// `onPartial` receives the text decoded so far; it is display-only and never stops decoding.
    func transcribe(_ samples: [Float], onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String? {
        guard let whisper else { throw TranscriberError.notReady }
        // The final pass has priority: stop any live preview and wait for it to wind down,
        // so the two never run on the model at once.
        stopPreview.set(true)
        _ = await previewTask?.value
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            usePrefillPrompt: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options, callback: { progress in
            onPartial?(TranscriptFilter.clean(progress.text) ?? "")
            return nil
        })
        let text = results.map(\.text).joined(separator: " ")
        return TranscriptFilter.clean(text)
    }

    /// Thread-safe flag read from WhisperKit's progress callback.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set(_ on: Bool) { lock.withLock { value = on } }
    }

    enum TranscriberError: LocalizedError {
        case notReady
        case modelInUse
        var errorDescription: String? {
            switch self {
            case .notReady: return "The speech model isn't loaded yet."
            case .modelInUse: return "That model is in use. Switch to another model first."
            }
        }
    }
}
