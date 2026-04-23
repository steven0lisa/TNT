import AVFoundation
import Foundation

/// 音频后处理器：音量归一化 + 静音裁剪
/// 适配 Qwen3-ASR 的 16kHz 单声道标准
final class AudioPostProcessor {
    private let targetLoudness: Float = -16.0
    private let silenceThreshold: Float = 0.01

    /// 对音频文件进行后处理：音量归一化 + 静音裁剪
    /// - Parameter fileURL: 输入 WAV 文件路径
    /// - Returns: 处理后的 WAV 文件路径（可能与输入相同，即原地处理）
    func process(fileURL: URL) -> URL? {
        guard let buffer = readWAV(url: fileURL) else {
            TNTLog.warning("[AudioPostProcessor] Failed to read WAV: \(fileURL.path)")
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            TNTLog.warning("[AudioPostProcessor] Empty audio buffer")
            return nil
        }

        let normalized = normalizeVolume(buffer)
        let trimmed = trimSilence(normalized)

        guard trimmed.frameLength > 0 else {
            TNTLog.warning("[AudioPostProcessor] No valid audio after trimming")
            return nil
        }

        // 原地覆盖原文件
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            TNTLog.debug("[AudioPostProcessor] Could not remove original: \(error)")
        }

        guard writeWAV(buffer: trimmed, url: fileURL) else {
            TNTLog.error("[AudioPostProcessor] Failed to write processed WAV")
            return nil
        }

        let originalDuration = Float(frameCount) / Float(buffer.format.sampleRate)
        let trimmedDuration = Float(trimmed.frameLength) / Float(trimmed.format.sampleRate)
        TNTLog.info("[AudioPostProcessor] Processed: \(String(format: "%.3f", originalDuration))s → \(String(format: "%.3f", trimmedDuration))s")

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

    /// 音量归一化（Float32 版本，样本范围 [-1.0, 1.0]）
    private func normalizeVolume(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
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
        let gain = targetRms / rms

        for i in 0..<count {
            let scaled = samples[i] * gain
            outputData[i] = max(-1.0, min(1.0, scaled))
        }

        TNTLog.debug("[AudioPostProcessor] Normalized: RMS=\(String(format: "%.4f", rms)), gain=\(String(format: "%.2f", gain))")
        return outputBuffer
    }

    /// 静音裁剪（Float32 版本）
    private func trimSilence(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let inputData = buffer.floatChannelData?[0] else {
            return buffer
        }
        let format = buffer.format

        let count = Int(buffer.frameLength)
        guard count > 0 else { return buffer }

        let samples = Array(UnsafeBufferPointer(start: inputData, count: count))

        // 找到非静音起始位置
        var startIndex = 0
        while startIndex < count && abs(samples[startIndex]) < silenceThreshold {
            startIndex += 1
        }

        // 找到非静音结束位置
        var endIndex = count - 1
        while endIndex > startIndex && abs(samples[endIndex]) < silenceThreshold {
            endIndex -= 1
        }

        // 无有效音频
        if startIndex >= endIndex {
            TNTLog.debug("[AudioPostProcessor] All silence, nothing to trim")
            return buffer
        }

        let trimmedCount = endIndex - startIndex + 1
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
        TNTLog.debug("[AudioPostProcessor] Trimmed head: \(String(format: "%.3f", trimmedHead))s, tail: \(String(format: "%.3f", trimmedTail))s")

        return trimmedBuffer
    }
}
