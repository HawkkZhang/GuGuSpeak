import AVFoundation
import Foundation

private struct SmokeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct RecognitionResult: Sendable {
    let partialCount: Int
    let finalText: String
}

@main
private enum CloudProviderSmoke {
    private static let settingsDomain = "com.end.DesktopVoiceInput"

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeFailure(message: "Usage: CloudProviderSmoke <16 kHz mono WAV>")
        }

        let wavURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let samples = try readSamples(from: wavURL)
        let config = try recognitionConfig()
        let corrector = PersonalLexiconCorrector()
        let terms = [PersonalTerm(text: "GuGuTalk")]

        var failures: [String] = []
        for (name, provider) in [
            ("doubao", DoubaoSpeechProvider() as SpeechProvider),
            ("qwen", QwenSpeechProvider() as SpeechProvider),
        ] {
            do {
                let result = try await recognize(
                    provider: provider,
                    config: config,
                    samples: samples
                )
                let personalized = await corrector.correct(result.finalText, terms: terms)
                guard personalized.contains("GuGuTalk") else {
                    throw SmokeFailure(message: "personal lexicon did not produce GuGuTalk")
                }

                print("CLOUD_SMOKE provider=\(name) status=ok partials=\(result.partialCount)")
                print("CLOUD_SMOKE provider=\(name) raw=\(result.finalText)")
                print("CLOUD_SMOKE provider=\(name) personalized=\(personalized)")
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                print("CLOUD_SMOKE provider=\(name) status=failed error=\(error.localizedDescription)")
            }
        }

        guard failures.isEmpty else {
            throw SmokeFailure(message: failures.joined(separator: "; "))
        }
    }

    private static func recognitionConfig() throws -> RecognitionConfig {
        guard let defaults = UserDefaults(suiteName: settingsDomain) else {
            throw SmokeFailure(message: "Unable to read the GuGuTalk settings domain")
        }

        let doubaoEndpoint = defaults.string(forKey: "doubaoEndpoint")
            ?? "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        let qwenModel = defaults.string(forKey: "qwenModel")
            ?? "qwen3-asr-flash-realtime"
        let qwenEndpoint = defaults.string(forKey: "qwenEndpoint")
            ?? "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        let config = RecognitionConfig(
            languageCode: "zh-CN",
            sampleRate: 16_000,
            mode: .local,
            partialResultsEnabled: true,
            endpointing: .manual,
            doubaoCredentials: DoubaoCredentials(
                appID: (defaults.string(forKey: "doubaoAppID") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                accessKey: (defaults.string(forKey: "doubaoAccessKey")
                    ?? defaults.string(forKey: "doubaoToken") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                resourceID: (defaults.string(forKey: "doubaoResourceID")
                    ?? defaults.string(forKey: "doubaoCluster")
                    ?? "volc.bigasr.sauc.duration")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: doubaoEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            qwenCredentials: QwenCredentials(
                apiKey: (defaults.string(forKey: "qwenAPIKey") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                model: qwenModel.trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: qwenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        guard config.doubaoCredentials.isConfigured else {
            throw SmokeFailure(message: "Doubao credentials are incomplete")
        }
        guard config.qwenCredentials.isConfigured else {
            throw SmokeFailure(message: "Qwen credentials are incomplete")
        }
        return config
    }

    private static func readSamples(from wavURL: URL) throws -> [Int16] {
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw SmokeFailure(message: "Missing smoke audio: \(wavURL.path)")
        }

        let file = try AVAudioFile(forReading: wavURL)
        let format = file.processingFormat
        guard Int(format.sampleRate) == 16_000, format.channelCount == 1 else {
            throw SmokeFailure(message: "Expected a 16 kHz mono WAV: \(wavURL.path)")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw SmokeFailure(message: "Unable to allocate an audio buffer")
        }
        try file.read(into: buffer)

        let count = Int(buffer.frameLength)
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let channel = buffer.floatChannelData?[0] else {
                throw SmokeFailure(message: "Unable to read Float32 WAV samples")
            }
            return (0..<count).map { index in
                let sample = max(-1, min(1, channel[index]))
                return Int16((sample * Float(Int16.max)).rounded())
            }
        case .pcmFormatInt16:
            guard let channel = buffer.int16ChannelData?[0] else {
                throw SmokeFailure(message: "Unable to read Int16 WAV samples")
            }
            return Array(UnsafeBufferPointer(start: channel, count: count))
        default:
            throw SmokeFailure(message: "Unsupported WAV sample format: \(format)")
        }
    }

    private static func recognize(
        provider: SpeechProvider,
        config: RecognitionConfig,
        samples: [Int16]
    ) async throws -> RecognitionResult {
        let eventTask = Task<RecognitionResult, Error> {
            var partialCount = 0
            for await event in provider.events {
                switch event {
                case .partialTextUpdated(let text, _):
                    if !text.isEmpty { partialCount += 1 }
                case .finalTextReady(let text):
                    guard !text.isEmpty else {
                        throw SmokeFailure(message: "Provider emitted an empty final result")
                    }
                    return RecognitionResult(partialCount: partialCount, finalText: text)
                case .sessionFailed(let failure):
                    throw failure
                case .sessionEnded:
                    throw SmokeFailure(message: "Session ended without final text")
                default:
                    continue
                }
            }
            throw SmokeFailure(message: "Provider event stream ended without final text")
        }

        do {
            try await provider.startSession(config: config)
            let chunkSize = 1_600
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                let chunkSamples = Array(samples[offset..<end])
                try await provider.sendAudio(makeAudioChunk(samples: chunkSamples))
                offset = end
                try await Task.sleep(for: .milliseconds(100))
            }

            let trailingSilence = Array(repeating: Int16(0), count: 9_600)
            for offset in stride(from: 0, to: trailingSilence.count, by: chunkSize) {
                let end = min(offset + chunkSize, trailingSilence.count)
                try await provider.sendAudio(
                    makeAudioChunk(samples: Array(trailingSilence[offset..<end]))
                )
                try await Task.sleep(for: .milliseconds(100))
            }
            try await provider.finishAudio()

            let result = try await withThrowingTaskGroup(of: RecognitionResult.self) { group in
                group.addTask { try await eventTask.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw SmokeFailure(message: "Timed out waiting for final text")
                }
                guard let first = try await group.next() else {
                    throw SmokeFailure(message: "No provider result")
                }
                group.cancelAll()
                return first
            }
            await provider.cancel()
            return result
        } catch {
            eventTask.cancel()
            await provider.cancel()
            throw error
        }
    }

    private static func makeAudioChunk(samples: [Int16]) -> AudioChunk {
        let pcmData = samples.withUnsafeBytes { Data($0) }
        let frameCount = AVAudioFrameCount(samples.count)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let nativeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        nativeBuffer.frameLength = frameCount
        return AudioChunk(
            pcmData: pcmData,
            sampleRate: 16_000,
            channels: 1,
            audioLevel: 0.5,
            nativeBuffer: nativeBuffer
        )
    }
}
