@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureEngine {
    typealias AudioHandler = @Sendable (AudioChunk) async -> Void

    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var audioHandler: AudioHandler?
    private var isPrewarmed = false

    /// 预热音频引擎，减少首次启动延迟
    /// 注意：只有在麦克风权限已授予后才能调用
    func prewarm() {
        guard !isPrewarmed else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let inputNode = audioEngine.inputNode
        _ = inputNode.outputFormat(forBus: 0)
        audioEngine.prepare()
        isPrewarmed = true
    }

    func startCapture(handler: @escaping AudioHandler) throws {
        stopCapture()

        audioHandler = handler

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let convertedBuffer = self.convert(buffer: buffer) else { return }
            guard let pcmData = convertedBuffer.int16PCMData else { return }
            let nativeBuffer = buffer.copyForAsyncUse() ?? convertedBuffer

            let audioLevel = convertedBuffer.rmsLevel
            let chunk = AudioChunk(
                pcmData: pcmData,
                sampleRate: self.targetFormat.sampleRate,
                channels: Int(self.targetFormat.channelCount),
                audioLevel: audioLevel,
                nativeBuffer: nativeBuffer
            )

            Task {
                await handler(chunk)
            }
        }

        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    func stopCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioHandler = nil
        audioConverter = nil
    }

    private func convert(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let audioConverter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var conversionError: NSError?
        let sourceBuffer = buffer
        let status = audioConverter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            NSLog("Audio conversion failed: \(conversionError.localizedDescription)")
            return nil
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return convertedBuffer
        default:
            return nil
        }
    }
}

private extension AVAudioPCMBuffer {
    func copyForAsyncUse() -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        copiedBuffer.frameLength = frameLength

        let frameCount = Int(frameLength)
        let channelCount = max(1, Int(format.channelCount))
        let buffersToCopy = format.isInterleaved ? 1 : channelCount
        let samplesPerBuffer = frameCount * (format.isInterleaved ? channelCount : 1)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = floatChannelData, let destination = copiedBuffer.floatChannelData else { return nil }
            for index in 0..<buffersToCopy {
                destination[index].update(from: source[index], count: samplesPerBuffer)
            }
        case .pcmFormatInt16:
            guard let source = int16ChannelData, let destination = copiedBuffer.int16ChannelData else { return nil }
            for index in 0..<buffersToCopy {
                destination[index].update(from: source[index], count: samplesPerBuffer)
            }
        case .pcmFormatInt32:
            guard let source = int32ChannelData, let destination = copiedBuffer.int32ChannelData else { return nil }
            for index in 0..<buffersToCopy {
                destination[index].update(from: source[index], count: samplesPerBuffer)
            }
        default:
            return nil
        }

        return copiedBuffer
    }

    var int16PCMData: Data? {
        guard let channelData = int16ChannelData else { return nil }
        let samples = Int(frameLength)
        return Data(bytes: channelData[0], count: samples * MemoryLayout<Int16>.size)
    }

    var rmsLevel: Float {
        guard let channelData = int16ChannelData else { return 0 }
        let samples = Int(frameLength)
        guard samples > 0 else { return 0 }
        let pointer = channelData[0]
        var sum: Float = 0
        for index in 0..<samples {
            let normalized = Float(pointer[index]) / Float(Int16.max)
            sum += normalized * normalized
        }
        return sqrt(sum / Float(samples))
    }
}
