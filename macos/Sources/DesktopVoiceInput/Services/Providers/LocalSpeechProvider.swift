import Foundation
import NaturalLanguage
import os

extension SherpaOnnxRecognizer: @unchecked Sendable {}
extension SherpaOnnxOfflinePunctuationWrapper: @unchecked Sendable {}

final class LocalSpeechProvider: SpeechProvider, @unchecked Sendable {
    let mode: RecognitionMode = .local
    let events: AsyncStream<TranscriptEvent>

    private struct SessionSnapshot: Sendable {
        let generation: Int
        let sampleRate: Int
        let chunkCount: Int
        let averageLevel: Float
        let audioByteCount: Int
    }

    private struct PartialUpdate: Sendable {
        let text: String
        let revision: Int
    }

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let stateLock = NSLock()
    private var sessionGeneration = 0
    private var sessionSampleRate = 16_000
    private var sessionIsOpen = false
    private var sessionAcceptsAudio = false
    private var hasTerminated = false
    private var appendedChunkCount = 0
    private var audioByteCount = 0
    private var audioLevelSum: Float = 0
    private var revision = 0
    private var lastPartialRawText = ""
    private var lastPartialText = ""
    private var lastPartialAt: TimeInterval = 0

    private static let partialPunctuationInterval: TimeInterval = 0.25
    private static let leadingPaddingSeconds = 0.3
    private static let trailingPaddingSeconds = 0.6

    private static let recognizerLock = NSLock()
    nonisolated(unsafe) private static var cachedRecognizer: SherpaOnnxRecognizer?
    nonisolated(unsafe) private static var cachedPunctuation: SherpaOnnxOfflinePunctuationWrapper?
    nonisolated(unsafe) private static var cachedRuntimeKey: String?

    private static let logger = Logger(subsystem: "com.desktopvoiceinput", category: "LocalStreamingASR")

    init() {
        var continuation: AsyncStream<TranscriptEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation!
    }

    func startSession(config: RecognitionConfig) async throws {
        let sampleRate = Int(config.sampleRate)
        let generation = beginStartingSession(sampleRate: sampleRate)

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.prepareRecognizer(sampleRate: sampleRate)
            }.value
        } catch let failure as SessionFailureInfo {
            invalidateSession(generation: generation)
            throw failure
        } catch {
            invalidateSession(generation: generation)
            throw SessionFailureInfo(message: "本地流式识别启动失败：\(error.localizedDescription)")
        }

        guard activateSession(generation: generation) else {
            throw SessionFailureInfo(message: "本地识别会话已取消")
        }

        continuation.yield(.sessionStarted(mode: mode))
        Self.logger.info("Local streaming ASR session ready. sampleRate=\(sampleRate, privacy: .public)")
    }

    func sendAudio(_ chunk: AudioChunk) async throws {
        guard let generation = recordAudioChunk(chunk) else {
            return
        }

        let pcmData = chunk.pcmData
        let sampleRate = Int(chunk.sampleRate)
        let update = await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil as PartialUpdate? }
            return self.decodeChunk(
                pcmData: pcmData,
                sampleRate: sampleRate,
                generation: generation
            )
        }.value

        if let update {
            continuation.yield(.partialTextUpdated(text: update.text, revision: update.revision))
        }
    }

    func finishAudio() async throws {
        guard let snapshot = beginFinishingSession() else {
            return
        }

        guard snapshot.audioByteCount > 0 else {
            continuation.yield(.sessionFailed(SessionFailureInfo(message: "没有收到有效音频", isNoSpeech: true)))
            finishSessionIfNeeded(generation: snapshot.generation)
            return
        }

        do {
            let finalText = try await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return "" }
                return try self.finalizeRecognition(
                    sampleRate: snapshot.sampleRate,
                    generation: snapshot.generation
                )
            }.value

            guard isSessionCurrent(snapshot.generation) else {
                return
            }

            Self.logger.info(
                "Streaming ASR finish. bytes=\(snapshot.audioByteCount, privacy: .public) chunks=\(snapshot.chunkCount, privacy: .public) avgLevel=\(snapshot.averageLevel, privacy: .public) textEmpty=\(finalText.isEmpty, privacy: .public)"
            )

            if finalText.isEmpty {
                continuation.yield(.sessionFailed(SessionFailureInfo(message: "说话时间太短，没有识别到内容", isNoSpeech: true)))
            } else {
                continuation.yield(.finalTextReady(text: finalText))
            }
        } catch let failure as SessionFailureInfo {
            if isSessionCurrent(snapshot.generation) {
                continuation.yield(.sessionFailed(failure))
            }
        } catch {
            Self.logger.error("Streaming ASR decode failed: \(error.localizedDescription, privacy: .public)")
            if isSessionCurrent(snapshot.generation) {
                continuation.yield(.sessionFailed(SessionFailureInfo(message: "本地识别失败：\(error.localizedDescription)")))
            }
        }

        finishSessionIfNeeded(generation: snapshot.generation)
    }

    func cancel() async {
        let shouldEnd = cancelCurrentSession()

        await Task.detached(priority: .utility) {
            Self.resetRecognizer()
        }.value

        if shouldEnd {
            continuation.yield(.sessionEnded)
        }
    }

    private func beginStartingSession(sampleRate: Int) -> Int {
        stateLock.lock()
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionSampleRate = sampleRate
        sessionIsOpen = true
        sessionAcceptsAudio = false
        hasTerminated = false
        appendedChunkCount = 0
        audioByteCount = 0
        audioLevelSum = 0
        revision = 0
        lastPartialRawText = ""
        lastPartialText = ""
        lastPartialAt = 0
        stateLock.unlock()
        return generation
    }

    private func activateSession(generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionGeneration == generation, sessionIsOpen else {
            return false
        }
        sessionAcceptsAudio = true
        return true
    }

    private func invalidateSession(generation: Int) {
        stateLock.lock()
        if sessionGeneration == generation {
            sessionIsOpen = false
            sessionAcceptsAudio = false
            hasTerminated = true
        }
        stateLock.unlock()
    }

    private func recordAudioChunk(_ chunk: AudioChunk) -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionIsOpen, sessionAcceptsAudio else {
            return nil
        }
        sessionSampleRate = Int(chunk.sampleRate)
        appendedChunkCount += 1
        audioByteCount += chunk.pcmData.count
        audioLevelSum += chunk.audioLevel
        return sessionGeneration
    }

    private func beginFinishingSession() -> SessionSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionIsOpen, !hasTerminated else {
            return nil
        }
        sessionAcceptsAudio = false
        return SessionSnapshot(
            generation: sessionGeneration,
            sampleRate: sessionSampleRate,
            chunkCount: appendedChunkCount,
            averageLevel: appendedChunkCount > 0 ? audioLevelSum / Float(appendedChunkCount) : 0,
            audioByteCount: audioByteCount
        )
    }

    private func cancelCurrentSession() -> Bool {
        stateLock.lock()
        let shouldEnd = sessionIsOpen && !hasTerminated
        sessionGeneration += 1
        sessionIsOpen = false
        sessionAcceptsAudio = false
        hasTerminated = true
        stateLock.unlock()
        return shouldEnd
    }

    private func isSessionCurrent(_ generation: Int) -> Bool {
        stateLock.lock()
        let isCurrent = sessionGeneration == generation && sessionIsOpen && !hasTerminated
        stateLock.unlock()
        return isCurrent
    }

    private func shouldRunPartialPunctuation(rawText: String, generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionGeneration == generation, sessionIsOpen, sessionAcceptsAudio else {
            return false
        }
        guard !rawText.isEmpty, rawText != lastPartialRawText else {
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        return lastPartialRawText.isEmpty || now - lastPartialAt >= Self.partialPunctuationInterval
    }

    private func commitPartial(
        rawText: String,
        punctuatedText: String,
        generation: Int
    ) -> PartialUpdate? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionGeneration == generation, sessionIsOpen, sessionAcceptsAudio else {
            return nil
        }

        lastPartialRawText = rawText
        lastPartialAt = ProcessInfo.processInfo.systemUptime
        guard !punctuatedText.isEmpty, punctuatedText != lastPartialText else {
            return nil
        }

        lastPartialText = punctuatedText
        revision += 1
        return PartialUpdate(text: punctuatedText, revision: revision)
    }

    private func finishSessionIfNeeded(generation: Int) {
        stateLock.lock()
        guard sessionGeneration == generation, sessionIsOpen, !hasTerminated else {
            stateLock.unlock()
            return
        }
        sessionIsOpen = false
        sessionAcceptsAudio = false
        hasTerminated = true
        stateLock.unlock()
        continuation.yield(.sessionEnded)
    }

    private func decodeChunk(
        pcmData: Data,
        sampleRate: Int,
        generation: Int
    ) -> PartialUpdate? {
        let samples = Self.convertPcm16ToFloat(pcmData)
        guard !samples.isEmpty else { return nil }

        let candidate: (raw: String, punctuated: String)? = {
            Self.recognizerLock.lock()
            defer { Self.recognizerLock.unlock() }

            guard isSessionCurrent(generation),
                  let recognizer = Self.cachedRecognizer,
                  let punctuation = Self.cachedPunctuation else {
                return nil
            }

            recognizer.acceptWaveform(samples: samples, sampleRate: sampleRate)
            while recognizer.isReady() {
                recognizer.decode()
            }

            let recognizedText = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawText = LocalRepetitionNormalizer.normalize(recognizedText)
            guard shouldRunPartialPunctuation(rawText: rawText, generation: generation) else {
                return nil
            }

            let punctuated = Self.addPunctuation(to: rawText, using: punctuation)
            return (rawText, punctuated)
        }()

        guard let candidate else { return nil }
        return commitPartial(
            rawText: candidate.raw,
            punctuatedText: candidate.punctuated,
            generation: generation
        )
    }

    private func finalizeRecognition(sampleRate: Int, generation: Int) throws -> String {
        Self.recognizerLock.lock()
        defer { Self.recognizerLock.unlock() }

        guard isSessionCurrent(generation),
              let recognizer = Self.cachedRecognizer,
              let punctuation = Self.cachedPunctuation else {
            return ""
        }

        let trailingPadding = [Float](
            repeating: 0,
            count: Int(Double(sampleRate) * Self.trailingPaddingSeconds)
        )
        recognizer.acceptWaveform(samples: trailingPadding, sampleRate: sampleRate)
        recognizer.inputFinished()
        while recognizer.isReady() {
            recognizer.decode()
        }

        let recognizedText = recognizer.getResult().text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText = LocalRepetitionNormalizer.normalize(recognizedText)
        guard !rawText.isEmpty else { return "" }
        return Self.addPunctuation(to: rawText, using: punctuation)
    }

    private static func prepareRecognizer(sampleRate: Int) throws {
        let models = try LocalAsrModelManager.resolveModels()
        let key = "\(models.cacheKey)#\(sampleRate)"

        recognizerLock.lock()
        defer { recognizerLock.unlock() }

        if cachedRecognizer == nil || cachedPunctuation == nil || cachedRuntimeKey != key {
            logger.info("Loading streaming Paraformer. dir=\(models.asr.directory.path, privacy: .public)")

            let paraformerConfig = sherpaOnnxOnlineParaformerModelConfig(
                encoder: models.asr.encoder.path,
                decoder: models.asr.decoder.path
            )
            let modelConfig = sherpaOnnxOnlineModelConfig(
                tokens: models.asr.tokens.path,
                paraformer: paraformerConfig,
                numThreads: 2,
                provider: "cpu",
                debug: 0
            )
            let featConfig = sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 80)
            var recognizerConfig = sherpaOnnxOnlineRecognizerConfig(
                featConfig: featConfig,
                modelConfig: modelConfig,
                enableEndpoint: false,
                decodingMethod: "greedy_search"
            )

            let punctuationModelConfig = sherpaOnnxOfflinePunctuationModelConfig(
                ctTransformer: models.punctuation.model.path,
                numThreads: 1,
                debug: 0,
                provider: "cpu"
            )
            var punctuationConfig = sherpaOnnxOfflinePunctuationConfig(model: punctuationModelConfig)

            cachedRecognizer = SherpaOnnxRecognizer(config: &recognizerConfig)
            cachedPunctuation = SherpaOnnxOfflinePunctuationWrapper(config: &punctuationConfig)
            cachedRuntimeKey = key
        } else {
            cachedRecognizer?.reset()
        }

        let leadingPadding = [Float](
            repeating: 0,
            count: Int(Double(sampleRate) * leadingPaddingSeconds)
        )
        cachedRecognizer?.acceptWaveform(samples: leadingPadding, sampleRate: sampleRate)
    }

    private static func resetRecognizer() {
        recognizerLock.lock()
        cachedRecognizer?.reset()
        recognizerLock.unlock()
    }

    private static func addPunctuation(
        to rawText: String,
        using punctuation: SherpaOnnxOfflinePunctuationWrapper
    ) -> String {
        let punctuated = punctuation.addPunct(text: rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalPunctuationNormalizer.normalize(punctuated.isEmpty ? rawText : punctuated)
    }

    private static func convertPcm16ToFloat(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)

        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }

            for index in 0..<sampleCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: high | low)
                samples[index] = Float(sample) / 32768.0
            }
        }

        return samples
    }
}

enum LocalRepetitionNormalizer {
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            tokens.append(range)
            return true
        }
        guard tokens.count > 1 else { return text }

        var removals: [Range<String.Index>] = []
        for index in 1..<tokens.count {
            let previousRange = tokens[index - 1]
            let currentRange = tokens[index]
            guard previousRange.upperBound == currentRange.lowerBound else { continue }

            let previous = text[previousRange]
            let current = text[currentRange]
            guard previous.last == current.first else { continue }

            if current.count > 1,
               let repeatedCharacter = previous.first,
               previous.allSatisfy({ $0 == repeatedCharacter }),
               repeatedCharacter == current.first {
                if removals.last != previousRange {
                    removals.append(previousRange)
                }
            } else if current.count == 1 {
                if removals.last != currentRange {
                    removals.append(currentRange)
                }
            }
        }

        guard !removals.isEmpty else { return text }

        var normalized = ""
        var cursor = text.startIndex
        for range in removals {
            normalized.append(contentsOf: text[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        normalized.append(contentsOf: text[cursor..<text.endIndex])
        return normalized
    }
}

enum LocalPunctuationNormalizer {
    private static let asciiPunctuation: [Character: Character] = [
        "，": ",",
        "。": ".",
        "！": "!",
        "？": "?",
        "；": ";",
        "：": ":",
    ]

    static func normalize(_ text: String) -> String {
        var result = ""
        var previousNonWhitespace: Character?

        for character in text {
            let normalized: Character
            if let replacement = asciiPunctuation[character],
               let previousNonWhitespace,
               isASCIIAlphaNumeric(previousNonWhitespace) {
                normalized = replacement
            } else {
                normalized = character
            }

            result.append(normalized)
            if !isWhitespace(normalized) {
                previousNonWhitespace = normalized
            }
        }

        return result
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else {
            return false
        }
        let value = scalar.value
        return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }
}
