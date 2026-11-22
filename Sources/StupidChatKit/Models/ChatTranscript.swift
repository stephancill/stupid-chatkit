import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// A voice message as text, transcribed on the device, and the language it was heard in.
public struct ChatTranscript: Codable, Equatable, Sendable {
    public let text: String
    /// The locale's identifier, such as "de_DE".
    public let locale: String

    public init(text: String, locale: String) {
        self.text = text
        self.locale = locale
    }
}

public enum ChatTranscriptionError: Error {
    /// This device can't transcribe: before iOS 26, or without the models' hardware (the simulator).
    case unavailable
    /// None of the languages tried is one the device can transcribe.
    case unsupportedLanguage
    /// The audio couldn't be fetched.
    case audioUnavailable
    /// Nothing was heard.
    case noSpeech
    /// Speech was heard, but no language tried made it out: likely one the device can't transcribe.
    case notUnderstood
}

/// Transcribes voice messages on the device: with `SpeechTranscriber` where the device runs it and knows the
/// language, else with `DictationTranscriber`, which knows more languages and runs where `SpeechTranscriber` doesn't
/// (the simulator: observed 2026-11-22, iOS 27). Speech has no language detection, so a message is transcribed in
/// each of the user's languages (`ChatKit.transcriptionLanguages`), and the result kept is the most confident one
/// whose text `NLLanguageRecognizer` reads as that language. Confidence alone picks wrongly: a Spanish model
/// transcribes English almost perfectly and can be more confident about it.
@available(iOS 26, *)
enum ChatVoiceTranscriber {
    enum Engine {
        case speech
        case dictation
    }

    /// A first language this sure of itself is kept without trying the others.
    private static let confidentEnough = 0.85
    /// Below this the best transcript is taken to be a language the device doesn't know, transcribed as the nearest
    /// one it does: real English voice notes scored 0.71–0.88 in English, Afrikaans ones at most 0.45 in Dutch or
    /// English, as fluent but wrong text (measured on the Mac, 2026-11-22).
    private static let understoodEnough = 0.55

    /// The languages, in order, that the device can transcribe, and what transcribes each.
    static func supported(_ languages: [Locale]) async -> [(locale: Locale, engine: Engine)] {
        var supported: [(locale: Locale, engine: Engine)] = []
        for language in languages {
            let match: (Locale, Engine)? = if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language) {
                (locale, .speech)
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: language) {
                (locale, .dictation)
            } else {
                nil
            }
            if let match, !supported.contains(where: { $0.locale.identifier == match.0.identifier }) {
                supported.append(match)
            }
        }
        return supported
    }

    /// Every language the device can transcribe, for choosing one by hand.
    static func supportedLanguages() async -> [Locale] {
        let speech = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let dictation = await DictationTranscriber.supportedLocales
        var seen: Set<String> = []
        return (speech + dictation)
            .filter { seen.insert($0.identifier).inserted }
            .sorted { name($0) < name($1) }
    }

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Tries the languages in order (the user's, or one they chose).
    static func transcribe(fileURL: URL, languages: [Locale]) async throws -> ChatTranscript {
        let candidates = await supported(languages)
        guard !candidates.isEmpty else { throw ChatTranscriptionError.unsupportedLanguage }
        var best: (transcript: ChatTranscript, score: Double)?
        for (locale, engine) in candidates {
            let (text, confidence) = switch engine {
            case .speech:
                try await transcribe(
                    SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence]),
                    fileURL: fileURL,
                    text: \.text,
                )
            case .dictation:
                try await transcribe(
                    DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [.transcriptionConfidence]),
                    fileURL: fileURL,
                    text: \.text,
                )
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let score = isWritten(trimmed, in: locale) ? confidence : confidence / 2
            if score > best?.score ?? -1 {
                best = (ChatTranscript(text: trimmed, locale: locale.identifier), score)
            }
            if score >= confidentEnough { break }
        }
        guard let best else { throw ChatTranscriptionError.noSpeech }
        guard best.score >= understoodEnough else { throw ChatTranscriptionError.notUnderstood }
        return best.transcript
    }

    private static func isWritten(_ text: String, in locale: Locale) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage?.rawValue else { return false }
        // NaturalLanguage names Chinese "zh-Hans"/"zh-Hant"; Locale names its language "zh".
        return detected.split(separator: "-").first.map(String.init) == locale.language.languageCode?.identifier
    }

    /// The text and its mean word confidence, downloading the language's model first if it isn't on the device.
    private static func transcribe<Module: SpeechModule>(
        _ module: Module,
        fileURL: URL,
        text: @escaping @Sendable (Module.Result) -> AttributedString,
    ) async throws -> (String, Double) {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        // Not every module takes every format (`DictationTranscriber` refuses Opus and AAC files as they decode), so
        // the audio goes in converted to the format the analyzer prefers.
        let input = try await converted(fileURL: fileURL, for: module)
        async let collected: (String, [Double]) = {
            var transcript = ""
            var confidences: [Double] = []
            for try await result in module.results {
                let resultText = text(result)
                transcript += String(resultText.characters)
                for run in resultText.runs {
                    if let confidence = run.transcriptionConfidence {
                        confidences.append(confidence)
                    }
                }
            }
            return (transcript, confidences)
        }()
        try await analyzer.start(inputSequence: AsyncStream { continuation in
            continuation.yield(AnalyzerInput(buffer: input))
            continuation.finish()
        })
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (transcript, confidences) = try await collected
        return (transcript, confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count))
    }

    /// The whole file decoded and converted to the analyzer's preferred format; voice messages are short enough to
    /// hold in memory.
    private static func converted(fileURL: URL, for module: some SpeechModule) async throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: fileURL)
        let source = file.processingFormat
        guard let decoded = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ChatTranscriptionError.audioUnavailable
        }
        try file.read(into: decoded)
        // No format at all means the device can't run the model, as on the simulator (observed 2026-11-22, iOS 27),
        // where `AnalyzerInput` traps on any buffer.
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: source) else {
            throw ChatTranscriptionError.unavailable
        }
        guard target != source else { return decoded }
        guard let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount((Double(decoded.frameLength) * target.sampleRate / source.sampleRate).rounded(.up)) + 1024,
              )
        else { throw ChatTranscriptionError.audioUnavailable }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return decoded
        }
        if status == .error {
            throw error ?? ChatTranscriptionError.audioUnavailable
        }
        return output
    }
}
