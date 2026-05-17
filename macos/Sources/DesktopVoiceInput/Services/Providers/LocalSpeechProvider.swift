@preconcurrency import AVFoundation
import Foundation
import Speech
import os

final class LocalSpeechProvider: NSObject, SpeechProvider, @unchecked Sendable {
    let mode: RecognitionMode = .local
    let events: AsyncStream<TranscriptEvent>

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var revision = 0
    private var committedTranscript = ""
    private var currentSegmentTranscript = ""
    private var lastNonEmptySegment = ""
    private var lastTranscriptLength = 0
    private var requestNativeFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var converterSourceDescription: String?
    private var appendedAudioDuration: TimeInterval = 0
    private var maxObservedAudioLevel: Float = 0
    private var appendedChunkCount = 0

    private static let logger = Logger(subsystem: "com.desktopvoiceinput", category: "LocalSpeech")

    override init() {
        var continuation: AsyncStream<TranscriptEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation!
        super.init()
    }

    func startSession(config: RecognitionConfig) async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SessionFailureInfo(message: "本地语音识别权限未授权。")
        }

        let locale = Locale(identifier: config.languageCode.replacingOccurrences(of: "-", with: "_"))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SessionFailureInfo(message: "本地语音识别器不可用。")
        }

        guard recognizer.isAvailable else {
            throw SessionFailureInfo(message: "本地语音识别当前不可用。")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        guard recognizer.supportsOnDeviceRecognition else {
            Self.logger.error("Apple Speech on-device recognition is unsupported. locale=\(locale.identifier, privacy: .public)")
            throw SessionFailureInfo(message: "当前 macOS 或语言包不支持本地离线识别（\(config.languageCode)）。请在系统设置中确认听写/语音识别资源已安装，或临时切换到豆包/千问。")
        }

        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        self.recognizer = recognizer
        self.recognitionRequest = request
        self.requestNativeFormat = request.nativeAudioFormat
        self.audioConverter = nil
        self.converterSourceDescription = nil
        self.revision = 0
        self.committedTranscript = ""
        self.currentSegmentTranscript = ""
        self.lastNonEmptySegment = ""
        self.lastTranscriptLength = 0
        self.appendedAudioDuration = 0
        self.maxObservedAudioLevel = 0
        self.appendedChunkCount = 0

        Self.logger.info("Starting Apple Speech local session. locale=\(locale.identifier, privacy: .public) available=\(recognizer.isAvailable, privacy: .public) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public) requestNativeFormat=\(request.nativeAudioFormat.description, privacy: .public)")

        continuation.yield(.sessionStarted(mode: mode))

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                if let result {
                    self.updateTranscriptState(with: result)
                }

                // 在清理前，尝试从最后的 partial 结果中提取 final
                var finalText = self.committedTranscript + self.currentSegmentTranscript
                if finalText.isEmpty, !self.lastNonEmptySegment.isEmpty {
                    finalText = self.committedTranscript + self.lastNonEmptySegment
                }

                let failure = self.failureInfo(for: error)
                Self.logger.error("Apple Speech error. message=\(failure.message, privacy: .public) isNoSpeech=\(failure.isNoSpeech, privacy: .public) appendedChunks=\(self.appendedChunkCount, privacy: .public) appendedDuration=\(self.appendedAudioDuration, privacy: .public) maxAudioLevel=\(self.maxObservedAudioLevel, privacy: .public)")

                self.cleanupRecognitionResources(cancelTask: false)

                // 如果有内容，先发送 finalTextReady，再发送 sessionEnded（不发送 sessionFailed）
                if !finalText.isEmpty {
                    Self.logger.info("Apple Speech returned error but have partial results, using them as final: [\(finalText, privacy: .public)]")
                    self.continuation.yield(.finalTextReady(text: finalText))
                    self.continuation.yield(.sessionEnded)
                } else {
                    self.continuation.yield(.sessionFailed(failure))
                    self.continuation.yield(.sessionEnded)
                }
                return
            }

            guard let result else { return }

            self.updateTranscriptState(with: result)
            let fullTranscript = self.committedTranscript + self.currentSegmentTranscript

            Self.logger.debug("Local speech: isFinal=\(result.isFinal) current=[\(self.currentSegmentTranscript, privacy: .public)] full=[\(fullTranscript, privacy: .public)]")

            if result.isFinal {
                self.cleanupRecognitionResources(cancelTask: false)
                // Final fallback：如果 final 回调时 current/committed 都已被清空，
                // 回退到我们自己记录的 lastNonEmptySegment + committed。
                var finalText = self.committedTranscript + self.currentSegmentTranscript
                if finalText.isEmpty, !self.lastNonEmptySegment.isEmpty {
                    Self.logger.debug("Final text empty, falling back to last non-empty segment: [\(self.lastNonEmptySegment, privacy: .public)]")
                    finalText = self.committedTranscript + self.lastNonEmptySegment
                }
                Self.logger.debug("Final result: [\(finalText, privacy: .public)]")
                self.continuation.yield(.finalTextReady(text: finalText))
                self.continuation.yield(.sessionEnded)
            } else {
                self.continuation.yield(.partialTextUpdated(text: fullTranscript, revision: self.revision))
            }
        }
    }

    func sendAudio(_ chunk: AudioChunk) async throws {
        guard let recognitionRequest else { return }
        guard let speechBuffer = speechBuffer(from: chunk) else {
            throw SessionFailureInfo(message: "本地识别音频格式转换失败。")
        }

        appendedAudioDuration += speechBuffer.estimatedDuration
        maxObservedAudioLevel = max(maxObservedAudioLevel, chunk.audioLevel)
        appendedChunkCount += 1

        if appendedChunkCount <= 3 {
            Self.logger.info("Appending local speech audio. chunk=\(self.appendedChunkCount, privacy: .public) sourceFormat=\(chunk.nativeBuffer.format.description, privacy: .public) requestFormat=\(speechBuffer.format.description, privacy: .public) duration=\(speechBuffer.estimatedDuration, privacy: .public) level=\(chunk.audioLevel, privacy: .public)")
        }

        recognitionRequest.append(speechBuffer)
    }

    func finishAudio() async throws {
        recognitionRequest?.endAudio()
    }

    func cancel() async {
        cleanupRecognitionResources(cancelTask: true)
        continuation.yield(.sessionEnded)
    }

    private func cleanupRecognitionResources(cancelTask: Bool) {
        if cancelTask {
            recognitionTask?.cancel()
        }

        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
        requestNativeFormat = nil
        audioConverter = nil
        converterSourceDescription = nil
    }

    private func updateTranscriptState(with result: SFSpeechRecognitionResult) {
        revision += 1
        let transcript = result.bestTranscription.formattedString
        let currentLength = transcript.count

        // 段落切换判定：长度回落（哪怕回落到 0）或完全清空都意味着 Apple Speech
        // 认为上一段已经结束、新的段落开始。必须先把旧段落 commit，避免被覆盖丢失。
        let isSegmentReset = currentLength == 0
            || currentLength < Int(Double(lastTranscriptLength) * 0.6)
        if isSegmentReset {
            if !currentSegmentTranscript.isEmpty {
                Self.logger.debug("Segment reset: committing [\(self.currentSegmentTranscript, privacy: .public)] (old length=\(self.lastTranscriptLength, privacy: .public), new length=\(currentLength, privacy: .public))")
                committedTranscript += currentSegmentTranscript
            }
            currentSegmentTranscript = transcript
        } else {
            currentSegmentTranscript = transcript
        }

        if !currentSegmentTranscript.isEmpty {
            lastNonEmptySegment = currentSegmentTranscript
        }
        lastTranscriptLength = currentLength
    }

    private func speechBuffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard let targetFormat = requestNativeFormat else {
            return chunk.nativeBuffer
        }

        let sourceBuffer = chunk.nativeBuffer
        guard !sourceBuffer.format.isSpeechEquivalent(to: targetFormat) else {
            return sourceBuffer
        }

        let sourceDescription = sourceBuffer.format.description
        if audioConverter == nil || converterSourceDescription != sourceDescription {
            audioConverter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat)
            converterSourceDescription = sourceDescription
            Self.logger.info("Created local speech audio converter. from=\(sourceDescription, privacy: .public) to=\(targetFormat.description, privacy: .public)")
        }

        guard let audioConverter else { return nil }
        return convert(buffer: sourceBuffer, converter: audioConverter, targetFormat: targetFormat)
    }

    private func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var conversionError: NSError?
        let sourceBuffer = buffer
        let inputState = AudioConverterInputState()
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            guard inputState.takeInput() else {
                outStatus.pointee = .noDataNow
                return nil
            }

            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            Self.logger.error("Local speech audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return convertedBuffer
        default:
            Self.logger.error("Local speech audio conversion returned unexpected status: \(String(describing: status), privacy: .public)")
            return nil
        }
    }

    private func failureInfo(for error: Error) -> SessionFailureInfo {
        let nsError = error as NSError
        let rawMessage = error.localizedDescription
        let isDictationDisabled = nsError.domain == "kSRErrorDomain" && nsError.code == 201
            || rawMessage.localizedCaseInsensitiveContains("siri and dictation are disabled")
            || rawMessage.localizedCaseInsensitiveContains("dictation")

        if isDictationDisabled {
            return SessionFailureInfo(
                message: "系统听写已关闭，本地识别不可用。请打开「系统设置 > 键盘 > 听写」，启用听写后再试；也可以先切换到豆包/千问。",
                isNoSpeech: false
            )
        }

        let isAppleNoSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
            || rawMessage.localizedCaseInsensitiveContains("no speech")
            || rawMessage.localizedCaseInsensitiveContains("没有语音")
        let heardAudibleAudio = appendedAudioDuration >= 0.5 && maxObservedAudioLevel >= 0.01

        if isAppleNoSpeech, !heardAudibleAudio {
            return SessionFailureInfo(message: "说话时间太短，没有识别到内容", isNoSpeech: true)
        }

        if isAppleNoSpeech, heardAudibleAudio {
            return SessionFailureInfo(
                message: "本地识别引擎没有返回文字，但麦克风已经收到声音。这个现象通常和当前 macOS 的本地语音识别模型或音频格式兼容有关，建议切换到豆包/千问，或更新/重装系统听写语言资源。",
                isNoSpeech: false
            )
        }

        let message = "本地识别引擎失败：\(rawMessage)（\(nsError.domain) \(nsError.code)）"
        return SessionFailureInfo(message: message, isNoSpeech: false)
    }
}

private extension AVAudioFormat {
    func isSpeechEquivalent(to other: AVAudioFormat) -> Bool {
        sampleRate == other.sampleRate
            && channelCount == other.channelCount
            && commonFormat == other.commonFormat
            && isInterleaved == other.isInterleaved
    }
}

private extension AVAudioPCMBuffer {
    var estimatedDuration: TimeInterval {
        guard format.sampleRate > 0 else { return 0 }
        return TimeInterval(frameLength) / format.sampleRate
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var didProvideInput = false

    func takeInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else { return false }
        didProvideInput = true
        return true
    }
}
