import AVFoundation
import Foundation

/// 音频后处理器：音量归一化 + 双阈值静音裁剪 + 首尾渐变
/// 适配 SFSpeechRecognizer 的 16kHz 单声道标准
final class AudioPostProcessor {
    private let targetLoudness: Float = -16.0

    // 内置麦阈值
    private let builtInStartThreshold: Float = 0.02
    private let builtInEndThreshold: Float = 0.01
    // 蓝牙麦阈值（更高，过滤更多底噪）
    private let bluetoothStartThreshold: Float = 0.04
    private let bluetoothEndThreshold: Float = 0.025
    // 最短有效音频 120ms @16kHz
    private let minValidSamples: Int = 1920
    // 首尾渐变时长 50ms @16kHz = 800 samples
    private let fadeSamples: Int = 800
    // 增益上限
    private let builtInMaxGain: Float = 8.0
    private let bluetoothMaxGain: Float = 4.0

    /// 对音频文件进行后处理：音量归一化 + 静音裁剪
    /// - Parameters:
    ///   - fileURL: 输入 WAV 文件路径
    ///   - isBluetooth: 是否蓝牙输入设备
    /// - Returns: 处理后的 WAV 文件路径（原地处理）
    func process(fileURL: URL, isBluetooth: Bool = false) -> URL? {
        guard let buffer = readWAV(url: fileURL) else {
            TNTLog.warning("[AudioPostProcessor] Failed to read WAV: \(fileURL.path)")
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            TNTLog.warning("[AudioPostProcessor] Empty audio buffer")
            return nil
        }

        let maxGain = isBluetooth ? bluetoothMaxGain : builtInMaxGain
        let normalized = normalizeVolume(buffer, maxGain: maxGain)
        let trimmed = trimSilence(normalized, isBluetooth: isBluetooth)

        guard trimmed.frameLength > 0 else {
            TNTLog.warning("[AudioPostProcessor] No valid audio after trimming")
            return nil
        }

        let faded = applyFadeInOut(trimmed)

        // 原地覆盖原文件
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            TNTLog.debug("[AudioPostProcessor] Could not remove original: \(error)")
        }

        guard writeWAV(buffer: faded, url: fileURL) else {
            TNTLog.error("[AudioPostProcessor] Failed to write processed WAV")
            return nil
        }

        let originalDuration = Float(frameCount) / Float(buffer.format.sampleRate)
        let trimmedDuration = Float(faded.frameLength) / Float(faded.format.sampleRate)
        let deviceTag = isBluetooth ? "BT" : "BuiltIn"
        TNTLog.info("[AudioPostProcessor] [\(deviceTag)] Processed: \(String(format: "%.3f", originalDuration))s → \(String(format: "%.3f", trimmedDuration))s")

        return fileURL
    }

    // MARK: - Private

    private func readWAV(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try? file.read(into: buffer)
        return buffer
    }

    private func writeWAV(buffer: AVAudioPCMBuffer, url: URL) -> Bool {
        guard let file = try? AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        ) else { return false }
        try? file.write(from: buffer)
        return true
    }

    /// 音量归一化，带增益上限保护
    private func normalizeVolume(_ buffer: AVAudioPCMBuffer, maxGain: Float) -> AVAudioPCMBuffer {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let inputData = buffer.floatChannelData?[0] else {
            return buffer
        }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let outputData = outputBuffer.floatChannelData?[0] else {
            return buffer
        }
        outputBuffer.frameLength = buffer.frameLength

        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: inputData, count: count))

        // 计算 RMS
        let sumSquares = samples.map { $0 * $0 }.reduce(0, +)
        let rms = sqrt(sumSquares / Float(count))
        guard rms > 1e-6 else {
            TNTLog.debug("[AudioPostProcessor] RMS too low, skipping normalization")
            return buffer
        }

        let targetRms = pow(10, targetLoudness / 20)
        let rawGain = targetRms / rms
        let gain = min(rawGain, maxGain)

        for i in 0..<count {
            let scaled = samples[i] * gain
            outputData[i] = max(-1.0, min(1.0, scaled))
        }

        TNTLog.debug("[AudioPostProcessor] Normalized: RMS=\(String(format: "%.4f", rms)), gain=\(String(format: "%.2f", gain)) (cap=\(maxGain))")
        return outputBuffer
    }

    /// 双阈值静音裁剪 + 最短时长过滤
    private func trimSilence(_ buffer: AVAudioPCMBuffer, isBluetooth: Bool) -> AVAudioPCMBuffer {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let inputData = buffer.floatChannelData?[0] else {
            return buffer
        }
        let format = buffer.format

        let count = Int(buffer.frameLength)
        guard count > 0 else { return buffer }

        let samples = Array(UnsafeBufferPointer(start: inputData, count: count))

        let startThreshold = isBluetooth ? bluetoothStartThreshold : builtInStartThreshold
        let endThreshold = isBluetooth ? bluetoothEndThreshold : builtInEndThreshold

        // 找人声起始位置（严格阈值）
        var startIndex = 0
        while startIndex < count && abs(samples[startIndex]) < startThreshold {
            startIndex += 1
        }

        // 找人声结束位置（宽松阈值）
        var endIndex = count - 1
        while endIndex > startIndex && abs(samples[endIndex]) < endThreshold {
            endIndex -= 1
        }

        let trimmedCount = endIndex - startIndex + 1

        // 无有效音频
        if startIndex >= endIndex || trimmedCount == 0 {
            TNTLog.debug("[AudioPostProcessor] All silence, nothing to trim")
            return buffer
        }

        // 最短有效音频过滤
        if trimmedCount < minValidSamples {
            TNTLog.debug("[AudioPostProcessor] Trimmed audio too short (\(trimmedCount) samples < \(minValidSamples)), returning empty")
            let emptyBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
            emptyBuffer.frameLength = 0
            return emptyBuffer
        }

        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimmedCount)),
              let outputData = trimmedBuffer.floatChannelData?[0] else {
            return buffer
        }
        trimmedBuffer.frameLength = AVAudioFrameCount(trimmedCount)

        for i in 0..<trimmedCount {
            outputData[i] = samples[startIndex + i]
        }

        let trimmedHead = Float(startIndex) / Float(format.sampleRate)
        let trimmedTail = Float(count - 1 - endIndex) / Float(format.sampleRate)
        TNTLog.debug("[AudioPostProcessor] Trimmed head: \(String(format: "%.3f", trimmedHead))s (thresh=\(startThreshold)), tail: \(String(format: "%.3f", trimmedTail))s (thresh=\(endThreshold))")

        return trimmedBuffer
    }

    /// 首尾渐变（fade-in / fade-out），消除裁剪边界的爆音
    private func applyFadeInOut(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let inputData = buffer.floatChannelData?[0] else {
            return buffer
        }

        let count = Int(buffer.frameLength)
        let fadeLen = min(fadeSamples, count / 2) // 不超过音频长度的一半
        guard fadeLen > 0 else { return buffer }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let outputData = outputBuffer.floatChannelData?[0] else {
            return buffer
        }
        outputBuffer.frameLength = buffer.frameLength

        // 复制原始数据
        for i in 0..<count {
            outputData[i] = inputData[i]
        }

        // Fade-in：前 fadeLen 个样本从 0 线性渐变到 1
        for i in 0..<fadeLen {
            let factor = Float(i) / Float(fadeLen)
            outputData[i] = inputData[i] * factor
        }

        // Fade-out：最后 fadeLen 个样本从 1 线性渐变到 0
        for i in 0..<fadeLen {
            let idx = count - 1 - i
            let factor = Float(i) / Float(fadeLen)
            outputData[idx] = inputData[idx] * factor
        }

        TNTLog.debug("[AudioPostProcessor] Applied fade-in/out: \(fadeLen) samples (\(String(format: "%.1f", Float(fadeLen) / 16000.0 * 1000))ms)")
        return outputBuffer
    }
}
