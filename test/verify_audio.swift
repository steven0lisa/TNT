#!/usr/bin/env swift
import AVFoundation
import Foundation

// MARK: - 音频分析工具

struct AudioAnalysis {
    let duration: Float
    let rms: Float
    let peak: Float
    let silenceRatio: Float
}

func analyze(_ buffer: AVAudioPCMBuffer) -> AudioAnalysis {
    guard let data = buffer.floatChannelData?[0] else {
        return AudioAnalysis(duration: 0, rms: 0, peak: 0, silenceRatio: 1)
    }
    let count = Int(buffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: data, count: count))

    let sumSquares = samples.map { $0 * $0 }.reduce(0, +)
    let rms = sqrt(sumSquares / Float(count))
    let peak = samples.map(abs).max() ?? 0

    let silenceThreshold: Float = 0.01
    let silentSamples = samples.filter { abs($0) < silenceThreshold }.count
    let silenceRatio = Float(silentSamples) / Float(count)

    let duration = Float(count) / Float(buffer.format.sampleRate)
    return AudioAnalysis(duration: duration, rms: rms, peak: peak, silenceRatio: silenceRatio)
}

func format(_ analysis: AudioAnalysis) -> String {
    return String(format: "时长: %.3fs | RMS: %.4f | Peak: %.4f | 静音占比: %.1f%%",
                  analysis.duration, analysis.rms, analysis.peak, analysis.silenceRatio * 100)
}

// MARK: - 音量归一化 (Float32)

func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard let inputData = buffer.floatChannelData?[0],
          let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
          let outputData = outputBuffer.floatChannelData?[0] else {
        return buffer
    }
    outputBuffer.frameLength = buffer.frameLength

    let count = Int(buffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: inputData, count: count))

    let sumSquares = samples.map { $0 * $0 }.reduce(0, +)
    let rms = sqrt(sumSquares / Float(count))
    guard rms > 1e-6 else { return buffer }

    let targetLoudness: Float = -16.0
    let targetRms = pow(10, targetLoudness / 20)
    let gain = targetRms / rms

    for i in 0..<count {
        let scaled = samples[i] * gain
        outputData[i] = max(-1.0, min(1.0, scaled))
    }
    return outputBuffer
}

// MARK: - 静音裁剪 (Float32)

func trimSilence(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    guard let inputData = buffer.floatChannelData?[0] else {
        return buffer
    }
    let format = buffer.format

    let count = Int(buffer.frameLength)
    guard count > 0 else { return buffer }

    let samples = Array(UnsafeBufferPointer(start: inputData, count: count))
    let silenceThreshold: Float = 0.01

    var startIndex = 0
    while startIndex < count && abs(samples[startIndex]) < silenceThreshold {
        startIndex += 1
    }

    var endIndex = count - 1
    while endIndex > startIndex && abs(samples[endIndex]) < silenceThreshold {
        endIndex -= 1
    }

    if startIndex >= endIndex {
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
    return trimmedBuffer
}

// MARK: - 文件读写

func readWAV(_ url: URL) -> AVAudioPCMBuffer? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
    try? file.read(into: buffer)
    return buffer
}

func writeWAV(_ buffer: AVAudioPCMBuffer, _ url: URL) -> Bool {
    guard let file = try? AVAudioFile(
        forWriting: url,
        settings: buffer.format.settings,
        commonFormat: buffer.format.commonFormat,
        interleaved: buffer.format.isInterleaved
    ) else { return false }
    try? file.write(from: buffer)
    return true
}

// MARK: - 主程序

let inputURL = URL(fileURLWithPath: "/Users/steven0lisa/work/personal/TNT/test/data/test-01.wav")
let outputURL = URL(fileURLWithPath: "/Users/steven0lisa/work/personal/TNT/test/data/test-01-processed.wav")

print("=== TNT 音频后处理验证 ===\n")

// 1. 读取原始音频
guard let originalBuffer = readWAV(inputURL) else {
    print("错误：无法读取输入文件 \(inputURL.path)")
    exit(1)
}

let originalAnalysis = analyze(originalBuffer)
print("[原始音频] \(format(originalAnalysis))")

// 2. 音量归一化
let normalizedBuffer = normalize(originalBuffer)
let normalizedAnalysis = analyze(normalizedBuffer)
print("[归一化后] \(format(normalizedAnalysis))")

// 3. 静音裁剪
let trimmedBuffer = trimSilence(normalizedBuffer)
let trimmedAnalysis = analyze(trimmedBuffer)
print("[裁剪后  ] \(format(trimmedAnalysis))")

// 4. 保存处理后的文件
try? FileManager.default.removeItem(at: outputURL)
if writeWAV(trimmedBuffer, outputURL) {
    print("\n处理后的文件已保存: \(outputURL.path)")
} else {
    print("\n错误：保存文件失败")
    exit(1)
}

// 5. 对比摘要
print("\n=== 对比摘要 ===")
print(String(format: "时长变化: %.3fs → %.3fs (减少 %.1f%%)",
      originalAnalysis.duration, trimmedAnalysis.duration,
      (1 - trimmedAnalysis.duration / originalAnalysis.duration) * 100))
print(String(format: "RMS 变化: %.4f → %.4f (目标: -16dB ≈ 0.1581)",
      originalAnalysis.rms, trimmedAnalysis.rms))
print(String(format: "静音占比: %.1f%% → %.1f%%",
      originalAnalysis.silenceRatio * 100, trimmedAnalysis.silenceRatio * 100))

print("\n验证完成。")
