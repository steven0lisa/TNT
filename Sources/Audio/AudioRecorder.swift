import AVFoundation
import CoreAudio
import Foundation

final class AudioRecorder: NSObject, @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private var tempFile: AVAudioFile?
    private var tempFileURL: URL?

    var onAudioBuffer: ((Data) -> Void)?
    var onAmplitude: ((CGFloat) -> Void)?

    /// 原始音频副本（处理后保留，用于诊断）
    private(set) var originalFileURL: URL?

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

        // 在处理前复制原始音频（用于诊断）
        let originalURL = URL(fileURLWithPath: NSTemporaryDirectory() + "tnt_recording_original.wav")
        try? FileManager.default.removeItem(at: originalURL)
        try? FileManager.default.copyItem(at: finalURL, to: originalURL)
        originalFileURL = originalURL

        // 后处理：音量归一化 + 静音裁剪（传入蓝牙标志）
        let bt = Self.isBluetoothInputDevice()
        let processor = AudioPostProcessor()
        _ = processor.process(fileURL: finalURL, isBluetooth: bt)

        TNTLog.info("[AudioRecorder] Recording saved to \(finalURL.path) (bluetooth=\(bt))")
        return finalURL
    }

    // MARK: - Bluetooth Detection

    /// 检测当前默认输入设备是否为蓝牙设备
    static func isBluetoothInputDevice() -> Bool {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            TNTLog.debug("[AudioRecorder] Cannot get default input device")
            return false
        }

        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType

        let transportStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transportType
        )
        guard transportStatus == noErr else {
            TNTLog.debug("[AudioRecorder] Cannot get transport type for device \(deviceID)")
            return false
        }

        let isBT = transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
        if isBT {
            TNTLog.info("[AudioRecorder] Bluetooth input device detected (transport=\(transportType))")
        }
        return isBT
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

        // 计算实时 RMS 振幅
        let rms = Self.calculateRMS(dataToProcess)
        let normalizedAmplitude = min(CGFloat(rms) * 10.0, 1.0)
        onAmplitude?(normalizedAmplitude)

        let rawData = samplesToData(dataToProcess)
        writeDataDirectly(dataToProcess)
        onAudioBuffer?(rawData)
    }

    /// 计算 Float32 音频采样的 RMS
    private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
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
