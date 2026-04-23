import AVFoundation
import Foundation

final class AudioRecorder: NSObject, @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private var tempFile: AVAudioFile?
    private var tempFileURL: URL?

    var onAudioBuffer: ((Data) -> Void)?

    override init() {
        super.init()
    }

    func start() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        inputNode = engine.inputNode
        let inputFormat = inputNode!.outputFormat(forBus: 0)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            TNTLog.error("[AudioRecorder] Failed to create output format")
            return
        }

        let tempDir = NSTemporaryDirectory()
        let fileName = "tnt_recording_\(UUID().uuidString).wav"
        tempFileURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)

        guard let fileURL = tempFileURL else { return }

        do {
            tempFile = try AVAudioFile(
                forWriting: fileURL,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            TNTLog.error("[AudioRecorder] Failed to create temp file: \(error)")
            return
        }

        inputNode?.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleAudioTap(buffer: buffer, inputFormat: inputFormat, outputFormat: outputFormat)
        }

        do {
            try engine.start()
            TNTLog.info("[AudioRecorder] Started at \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch → 16kHz mono")
        } catch {
            TNTLog.error("[AudioRecorder] Failed to start: \(error)")
        }
    }

    func stop() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        tempFile = nil
        TNTLog.info("[AudioRecorder] Stopped")
    }

    func takeRecordingFile() -> URL? {
        guard let url = tempFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let finalURL = URL(fileURLWithPath: NSTemporaryDirectory() + "tnt_recording.wav")
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.moveItem(at: url, to: finalURL)
        TNTLog.info("[AudioRecorder] Recording saved to \(finalURL.path)")
        return finalURL
    }

    private func handleAudioTap(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let floatSamples = extractFloatSamples(from: buffer) else { return }

        let dataToProcess: [Float]
        if inputFormat.sampleRate == outputFormat.sampleRate {
            dataToProcess = floatSamples
        } else {
            dataToProcess = resampleAudio(
                samples: floatSamples,
                inputSampleRate: inputFormat.sampleRate,
                outputSampleRate: outputFormat.sampleRate
            )
        }

        let rawData = samplesToData(dataToProcess)
        writeDataDirectly(dataToProcess)
        onAudioBuffer?(rawData)
    }

    private func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        if buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let ptr = buffer.floatChannelData?[0] else { return nil }
            let count = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        } else if buffer.format.commonFormat == .pcmFormatInt16 {
            guard let int16Ptr = buffer.int16ChannelData?[0] else { return nil }
            let count = Int(buffer.frameLength)
            return (0..<count).map { Float(int16Ptr[$0]) / 32768.0 }
        }
        return nil
    }

    private func resampleAudio(samples: [Float], inputSampleRate: Double, outputSampleRate: Double) -> [Float] {
        let ratio = outputSampleRate / inputSampleRate
        let outputCount = max(1, Int(Double(samples.count) * ratio))
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcPos = Double(i) / ratio
            let srcIndex = Int(srcPos)
            let frac = Float(srcPos - Double(srcIndex))

            if srcIndex + 1 < samples.count {
                output[i] = samples[srcIndex] * (1 - frac) + samples[srcIndex + 1] * frac
            } else if srcIndex < samples.count {
                output[i] = samples[srcIndex]
            }
        }
        return output
    }

    private func samplesToData(_ samples: [Float]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private func writeDataDirectly(_ samples: [Float]) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        samples.withUnsafeBytes { rawPtr in
            if let floatPtr = rawPtr.baseAddress?.assumingMemoryBound(to: Float.self) {
                buffer.floatChannelData?[0].update(from: floatPtr, count: samples.count)
            }
        }

        DispatchQueue.main.async { [weak self] in
            do {
                try self?.tempFile?.write(from: buffer)
            } catch {
                TNTLog.error("[AudioRecorder] Write error: \(error)")
            }
        }
    }
}
