import AVFoundation
import Foundation

private enum SmokeFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            message
        }
    }
}

private struct DecodeResult {
    let partials: [String]
    let final: String
}

@main
private struct LocalAsrSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw SmokeFailure.message("Usage: LocalAsrSmoke <models root> <smoke audio directory>")
        }

        let modelsRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let audioDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        setenv("GUGUTALK_LOCAL_ASR_MODEL_DIR", modelsRoot.path, 1)
        setenv("GUGUTALK_LOCAL_PUNCTUATION_MODEL_DIR", modelsRoot.path, 1)

        let mixed = try await decode(audioDirectory.appendingPathComponent("0.wav"))
        try validateStreamingResult(mixed, filename: "0.wav", requiresMixedLanguage: true)

        let second = try await decode(audioDirectory.appendingPathComponent("1.wav"))
        try validateStreamingResult(second, filename: "1.wav", requiresMixedLanguage: false)

        print("0.wav partials=\(mixed.partials.count)\t\(mixed.final)")
        print("1.wav partials=\(second.partials.count)\t\(second.final)")
    }

    private static func validateStreamingResult(
        _ result: DecodeResult,
        filename: String,
        requiresMixedLanguage: Bool
    ) throws {
        guard !result.partials.isEmpty else {
            throw SmokeFailure.message("No streaming partial was emitted for \(filename)")
        }
        guard result.partials.contains(where: containsPunctuation) else {
            throw SmokeFailure.message("Streaming partials did not contain punctuation for \(filename): \(result.partials)")
        }
        guard !result.final.isEmpty, containsPunctuation(result.final) else {
            throw SmokeFailure.message("Final text did not contain punctuation for \(filename): \(result.final)")
        }

        if requiresMixedLanguage {
            let hasChinese = result.final.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value)
            }
            let hasEnglish = result.final.unicodeScalars.contains { scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            }
            guard hasChinese, hasEnglish, result.final.contains(" ") else {
                throw SmokeFailure.message("Expected mixed Chinese/English final text for \(filename): \(result.final)")
            }
        }
    }

    private static func containsPunctuation(_ text: String) -> Bool {
        text.contains(where: { "，。！？；：,.!?;:".contains($0) })
    }

    private static func decode(_ wavURL: URL) async throws -> DecodeResult {
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw SmokeFailure.message("Missing smoke audio: \(wavURL.path)")
        }

        let wave = SherpaOnnxWaveWrapper.readWave(filename: wavURL.path)
        guard wave.sampleRate == 16_000, !wave.samples.isEmpty else {
            throw SmokeFailure.message("Expected non-empty 16 kHz mono WAV: \(wavURL.path)")
        }

        let pcmSamples = wave.samples.map { sample -> Int16 in
            let scaled = max(-1, min(1, sample)) * Float(Int16.max)
            return Int16(scaled.rounded())
        }

        let provider = LocalSpeechProvider()
        let resultTask = Task<DecodeResult, Error> {
            var partials: [String] = []
            for await event in provider.events {
                switch event {
                case .partialTextUpdated(let text, _):
                    if !text.isEmpty, partials.last != text {
                        partials.append(text)
                    }
                case .finalTextReady(let text):
                    return DecodeResult(partials: partials, final: text)
                case .sessionFailed(let failure):
                    throw failure
                case .sessionEnded:
                    throw SmokeFailure.message("Session ended without final text for \(wavURL.lastPathComponent)")
                default:
                    continue
                }
            }
            throw SmokeFailure.message("Event stream ended without final text for \(wavURL.lastPathComponent)")
        }

        let config = RecognitionConfig(
            languageCode: "auto",
            sampleRate: Double(wave.sampleRate),
            mode: .local,
            partialResultsEnabled: true,
            endpointing: .manual,
            doubaoCredentials: DoubaoCredentials(appID: "", accessKey: "", resourceID: "", endpoint: ""),
            qwenCredentials: QwenCredentials(apiKey: "", model: "", endpoint: "")
        )
        try await provider.startSession(config: config)

        let chunkSize = 1_600
        var offset = 0
        while offset < pcmSamples.count {
            let end = min(offset + chunkSize, pcmSamples.count)
            let samples = Array(pcmSamples[offset..<end])
            try await provider.sendAudio(makeAudioChunk(samples: samples, sampleRate: wave.sampleRate))
            offset = end
        }

        try await provider.finishAudio()
        return try await resultTask.value
    }

    private static func makeAudioChunk(samples: [Int16], sampleRate: Int) -> AudioChunk {
        let pcmData = samples.withUnsafeBytes { Data($0) }
        let frameCount = AVAudioFrameCount(samples.count)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        let nativeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        nativeBuffer.frameLength = frameCount

        return AudioChunk(
            pcmData: pcmData,
            sampleRate: Double(sampleRate),
            channels: 1,
            audioLevel: 0.5,
            nativeBuffer: nativeBuffer
        )
    }
}
