import Foundation
import os

extension SherpaOnnxOfflineRecognizer: @unchecked Sendable {}

final class LocalSpeechProvider: SpeechProvider, @unchecked Sendable {
    let mode: RecognitionMode = .local
    let events: AsyncStream<TranscriptEvent>

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let stateLock = NSLock()
    private var sessionPcm = Data()
    private var sessionSampleRate = 16_000
    private var hasTerminated = false
    private var appendedChunkCount = 0
    private var audioLevelSum: Float = 0

    private static let recognizerLock = NSLock()
    nonisolated(unsafe) private static var cachedRecognizer: SherpaOnnxOfflineRecognizer?
    nonisolated(unsafe) private static var cachedRecognizerKey: String?

    private static let logger = Logger(subsystem: "com.desktopvoiceinput", category: "LocalSenseVoice")

    init() {
        var continuation: AsyncStream<TranscriptEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation!
    }

    func startSession(config: RecognitionConfig) async throws {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try Self.ensureRecognizer(sampleRate: Int(config.sampleRate))
            }.value
        } catch let failure as SessionFailureInfo {
            throw failure
        } catch {
            throw SessionFailureInfo(message: "本地 SenseVoice 启动失败：\(error.localizedDescription)")
        }

        resetSessionState(sampleRate: Int(config.sampleRate))

        continuation.yield(.sessionStarted(mode: mode))
        Self.logger.info("Local SenseVoice session ready. sampleRate=\(config.sampleRate, privacy: .public)")
    }

    func sendAudio(_ chunk: AudioChunk) async throws {
        appendAudioChunk(chunk)
    }

    private func resetSessionState(sampleRate: Int) {
        stateLock.lock()
        sessionPcm.removeAll(keepingCapacity: true)
        sessionSampleRate = sampleRate
        hasTerminated = false
        appendedChunkCount = 0
        audioLevelSum = 0
        stateLock.unlock()
    }

    private func appendAudioChunk(_ chunk: AudioChunk) {
        stateLock.lock()
        sessionPcm.append(chunk.pcmData)
        sessionSampleRate = Int(chunk.sampleRate)
        appendedChunkCount += 1
        audioLevelSum += chunk.audioLevel
        stateLock.unlock()
    }

    private func drainAudio() -> (pcm: Data, sampleRate: Int, chunkCount: Int, averageLevel: Float) {
        stateLock.lock()
        let pcm = sessionPcm
        sessionPcm.removeAll(keepingCapacity: true)
        let sampleRate = sessionSampleRate
        let chunkCount = appendedChunkCount
        let averageLevel = appendedChunkCount > 0 ? audioLevelSum / Float(appendedChunkCount) : 0
        stateLock.unlock()
        return (pcm, sampleRate, chunkCount, averageLevel)
    }

    private func clearAudio() {
        stateLock.lock()
        sessionPcm.removeAll(keepingCapacity: true)
        stateLock.unlock()
    }

    func finishAudio() async throws {
        let (pcm, sampleRate, chunkCount, averageLevel) = drainAudio()

        guard !pcm.isEmpty else {
            continuation.yield(.sessionFailed(SessionFailureInfo(message: "没有收到有效音频", isNoSpeech: true)))
            finishSessionIfNeeded()
            return
        }

        do {
            let finalText = try await Task.detached(priority: .userInitiated) {
                try Self.decode(pcmData: pcm, sampleRate: sampleRate)
            }.value

            Self.logger.info("SenseVoice finish. bytes=\(pcm.count, privacy: .public) chunks=\(chunkCount, privacy: .public) avgLevel=\(averageLevel, privacy: .public) textEmpty=\(finalText.isEmpty, privacy: .public)")

            if finalText.isEmpty {
                continuation.yield(.sessionFailed(SessionFailureInfo(message: "说话时间太短，没有识别到内容", isNoSpeech: true)))
            } else {
                continuation.yield(.finalTextReady(text: finalText))
            }
        } catch let failure as SessionFailureInfo {
            continuation.yield(.sessionFailed(failure))
        } catch {
            Self.logger.error("SenseVoice decode failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.sessionFailed(SessionFailureInfo(message: "本地识别失败：\(error.localizedDescription)")))
        }

        finishSessionIfNeeded()
    }

    func cancel() async {
        clearAudio()
        finishSessionIfNeeded()
    }

    private func finishSessionIfNeeded() {
        stateLock.lock()
        guard !hasTerminated else {
            stateLock.unlock()
            return
        }
        hasTerminated = true
        stateLock.unlock()
        continuation.yield(.sessionEnded)
    }

    private static func decode(pcmData: Data, sampleRate: Int) throws -> String {
        let samples = convertPcm16ToFloat(pcmData)
        let recognizer = try ensureRecognizer(sampleRate: sampleRate)

        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        let result = recognizer.decode(samples: samples, sampleRate: sampleRate)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func ensureRecognizer(sampleRate: Int) throws -> SherpaOnnxOfflineRecognizer {
        let model = try LocalAsrModelManager.resolveModel()
        let key = "\(model.cacheKey)#\(sampleRate)"

        recognizerLock.lock()
        defer { recognizerLock.unlock() }

        if let cachedRecognizer, cachedRecognizerKey == key {
            return cachedRecognizer
        }

        Self.logger.info("Loading SenseVoice model. dir=\(model.directory.path, privacy: .public)")

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: model.model.path,
            language: "auto",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: model.tokens.path,
            numThreads: 4,
            provider: "cpu",
            debug: 0,
            senseVoice: senseVoiceConfig
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 80)
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )

        let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
        cachedRecognizer = recognizer
        cachedRecognizerKey = key
        return recognizer
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
