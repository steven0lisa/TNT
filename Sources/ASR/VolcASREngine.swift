import Foundation
import zlib

/// 火山引擎（字节跳动）双向流式语音识别引擎
/// 使用 bigmodel_async 接口，WebSocket + 自定义二进制协议
final class VolcASREngine: @unchecked Sendable, ASREngineProtocol {
    static let shared = VolcASREngine()

    // MARK: - Configuration
    private var appId: String { ModelManager.shared.volcAppId }
    private var accessKey: String { ModelManager.shared.volcAccessKey }
    private var resourceId: String { ModelManager.shared.volcResourceId }

    private init() {}

    // MARK: - ASREngineProtocol
    func transcribe(fileURL: URL) async -> String {
        guard !appId.isEmpty, !accessKey.isEmpty else {
            TNTLog.error("[VolcASR] AppID or AccessKey not configured")
            return "ERROR: 火山引擎 ASR 未配置"
        }

        guard let audioData = try? Data(contentsOf: fileURL) else {
            return "ERROR: 无法读取音频文件"
        }

        guard let pcmData = parseAndConvertWAV(data: audioData) else {
            return "ERROR: 音频格式解析失败（需要 16kHz mono WAV/PCM）"
        }

        guard !pcmData.isEmpty else {
            return "ERROR: 音频数据为空"
        }

        return await performRecognition(pcmData: pcmData)
    }

    // MARK: - WAV Parsing & Format Conversion

    /// 解析 WAV 文件，必要时将 Float32 转换为 Int16 PCM
    private func parseAndConvertWAV(data: Data) -> Data? {
        guard data.count >= 44 else { return nil }

        // Verify RIFF/WAVE header
        guard String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            return nil
        }

        // Parse chunks
        var offset = 12
        var fmtChunk: Data?
        var dataChunk: Data?

        while offset < data.count - 8 {
            let chunkId = String(decoding: data[offset..<offset+4], as: UTF8.self)
            let chunkSize = Int(readUInt32LE(data: data, offset: offset + 4))
            let chunkEnd = offset + 8 + chunkSize
            guard chunkEnd <= data.count else { break }

            let chunkPayload = data.subdata(in: (offset + 8)..<chunkEnd)

            if chunkId == "fmt " {
                fmtChunk = chunkPayload
            } else if chunkId == "data" {
                dataChunk = chunkPayload
            }

            offset = chunkEnd
            if chunkSize % 2 == 1 { offset += 1 } // pad byte
        }

        guard let fmt = fmtChunk, let pcm = dataChunk else { return nil }

        let audioFormat = Int(readUInt16LE(data: fmt, offset: 0))
        let numChannels = Int(readUInt16LE(data: fmt, offset: 2))
        let sampleRate = Int(readUInt32LE(data: fmt, offset: 4))
        let bitsPerSample = Int(readUInt16LE(data: fmt, offset: 14))

        guard sampleRate == 16000, numChannels == 1 else {
            TNTLog.error("[VolcASR] Unsupported audio format: \(sampleRate)Hz, \(numChannels)ch, \(bitsPerSample)bit, format=\(audioFormat)")
            return nil
        }

        // Format 1 = PCM integer, Format 3 = IEEE float
        // Format 65534 (0xFFFE) = WAVEFORMATEXTENSIBLE (used by AVAudioFile for Float32)
        if (audioFormat == 1 || audioFormat == 65534) && bitsPerSample == 16 {
            return pcm
        } else if (audioFormat == 3 || audioFormat == 65534) && bitsPerSample == 32 {
            return convertFloat32ToInt16LE(pcm)
        } else {
            TNTLog.error("[VolcASR] Unsupported audio format code: \(audioFormat), bits: \(bitsPerSample)")
            return nil
        }
    }

    private func convertFloat32ToInt16LE(_ data: Data) -> Data {
        let sampleCount = data.count / 4
        var result = Data(capacity: sampleCount * 2)
        data.withUnsafeBytes { bytes in
            let floats = bytes.bindMemory(to: Float.self)
            for i in 0..<sampleCount {
                let clamped = max(-1.0, min(1.0, floats[i]))
                let intVal = Int16(clamping: Int32(clamped * 32767.0))
                // Little-endian
                result.append(UInt8(intVal & 0xFF))
                result.append(UInt8((intVal >> 8) & 0xFF))
            }
        }
        return result
    }

    private func readUInt16LE(data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - Gzip Compression (required by VolcEngine protocol)

    private func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16, // windowBits: 15 for max window, +16 for gzip format
            8,       // memLevel
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var result = Data()
        let chunkSize = 64 * 1024

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: bytes)
            stream.avail_in = uInt(data.count)

            var status: Int32 = Z_OK
            repeat {
                var outBuffer = [UInt8](repeating: 0, count: chunkSize)
                status = outBuffer.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                let have = chunkSize - Int(stream.avail_out)
                if have > 0 {
                    result.append(contentsOf: outBuffer.prefix(have))
                }
            } while status == Z_OK
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - WebSocket Recognition

    private func performRecognition(pcmData: Data) async -> String {
        guard let url = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async") else {
            return "ERROR: Invalid URL"
        }

        var request = URLRequest(url: url)
        request.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)

        // Thread-safe session state wrapper for Sendable compliance
        final class SessionState: @unchecked Sendable {
            var resultText = ""
            private var isCompleted = false
            private let lock = NSLock()
            private let continuation: CheckedContinuation<String, Never>

            init(continuation: CheckedContinuation<String, Never>) {
                self.continuation = continuation
            }

            func complete(with result: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !isCompleted else { return }
                isCompleted = true
                continuation.resume(returning: result)
            }
        }

        return await withCheckedContinuation { continuation in
            let state = SessionState(continuation: continuation)

            // Receive loop — wrapped in a reference box to satisfy Sendable
            final class ReceiveBox: @unchecked Sendable {
                var closure: (@Sendable () -> Void)?
            }
            let receiveBox = ReceiveBox()
            receiveBox.closure = { [weak self] in
                guard let self = self else { return }
                task.receive { result in
                    switch result {
                    case .success(let message):
                        if case .data(let data) = message {
                            if let text = self.parseBinaryResponse(data: data) {
                                if text == "__ERROR__" {
                                    state.complete(with: state.resultText.isEmpty ? "ERROR: 服务器返回错误" : state.resultText)
                                    return
                                }
                                if !text.isEmpty {
                                    state.resultText = text
                                }
                            }
                        }
                        receiveBox.closure?()
                    case .failure(let error):
                        TNTLog.error("[VolcASR] WebSocket receive error: \(error)")
                        state.complete(with: state.resultText.isEmpty ? "ERROR: \(error.localizedDescription)" : state.resultText)
                    }
                }
            }

            task.resume()
            receiveBox.closure?()

            // Send data
            Task {
                do {
                    // 1. Send full client request
                    let fullRequest = self.buildFullClientRequest()
                    try await task.send(.data(fullRequest))
                    TNTLog.info("[VolcASR] Sent full client request")

                    // 2. Stream audio chunks (200ms each @ 16kHz 16bit mono = 6400 bytes)
                    let chunkSize = 6400
                    let totalChunks = max(1, (pcmData.count + chunkSize - 1) / chunkSize)

                    for i in 0..<totalChunks {
                        let start = i * chunkSize
                        let end = min(start + chunkSize, pcmData.count)
                        let chunk = pcmData.subdata(in: start..<end)
                        let isLast = (i == totalChunks - 1)
                        // Server auto-assigns seq 1 to full client request, audio starts from 2
                        let seq = UInt32(i + 2)

                        let packet = self.buildAudioPacket(data: chunk, sequence: isLast ? nil : seq)
                        try await task.send(.data(packet))

                        // Stream at real-time rate: 6400 bytes = 200ms @ 16kHz 16bit mono
                        // Use 180ms interval to stay slightly ahead of real-time
                        if !isLast {
                            try await Task.sleep(nanoseconds: 180_000_000)
                        }
                    }
                    TNTLog.info("[VolcASR] Sent \(totalChunks) audio chunks, total \(pcmData.count) bytes")

                    // 3. Wait for server to finish processing
                    try await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds

                    task.cancel(with: .normalClosure, reason: nil)
                    state.complete(with: state.resultText)

                } catch {
                    TNTLog.error("[VolcASR] Send error: \(error)")
                    task.cancel(with: .goingAway, reason: nil)
                    state.complete(with: state.resultText.isEmpty ? "ERROR: \(error.localizedDescription)" : state.resultText)
                }
            }
        }
    }

    // MARK: - Binary Protocol Encoding

    /// Build full client request (JSON configuration, Gzip compressed)
    private func buildFullClientRequest() -> Data {
        // Header: 4 bytes
        //  Byte 0: version(4) + header_size(4)  = 0b0001_0001 = 0x11
        //  Byte 1: msg_type(4) + flags(4)        = 0b0001_0000 = 0x10 (full req, no seq)
        //  Byte 2: serialization(4) + compress(4) = 0b0001_0001 = 0x11 (JSON, Gzip)
        //  Byte 3: reserved                      = 0x00
        let header = Data([0x11, 0x10, 0x11, 0x00])

        let payload: [String: Any] = [
            "user": [
                "uid": "tnt-user",
                "platform": "macOS"
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": false
            ]
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let compressed = gzipCompress(payloadData) else {
            return header + writeUInt32BE(0)
        }

        return header + writeUInt32BE(UInt32(compressed.count)) + compressed
    }

    /// Build audio packet (normal chunk with sequence, or last chunk without sequence)
    /// All audio payloads are Gzip compressed per VolcEngine protocol specification.
    private func buildAudioPacket(data: Data, sequence: UInt32?) -> Data {
        guard let compressed = gzipCompress(data) else {
            TNTLog.warning("[VolcASR] Gzip compression failed for audio chunk")
            return Data()
        }

        if let seq = sequence {
            // Normal chunk with positive sequence number
            //  Byte 0: 0x11 (version=1, header_size=1)
            //  Byte 1: 0x21 (type=0b0010, flags=0b0001 = has positive seq)
            //  Byte 2: 0x01 (serialization=none, compression=Gzip)
            //  Byte 3: 0x00 (reserved)
            let header = Data([0x11, 0x21, 0x01, 0x00])
            return header + writeUInt32BE(seq) + writeUInt32BE(UInt32(compressed.count)) + compressed
        } else {
            // Last chunk (负包) - no sequence, just last indicator
            //  Byte 0: 0x11
            //  Byte 1: 0x22 (type=0b0010, flags=0b0010 = last chunk, no seq)
            //  Byte 2: 0x01 (serialization=none, compression=Gzip)
            //  Byte 3: 0x00
            let header = Data([0x11, 0x22, 0x01, 0x00])
            return header + writeUInt32BE(UInt32(compressed.count)) + compressed
        }
    }

    private func writeUInt32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    // MARK: - Binary Protocol Decoding

    private func parseBinaryResponse(data: Data) -> String? {
        guard data.count >= 4 else { return nil }

        let messageType = (data[1] >> 4) & 0x0F
        let flags = data[1] & 0x0F

        // Error response (0b1111)
        if messageType == 0b1111 {
            parseErrorResponse(data: data)
            return "__ERROR__"
        }

        // Full server response (0b1001)
        guard messageType == 0b1001 else { return nil }

        var offset = 4

        // Skip sequence number if present
        if (flags & 0x01) != 0 || flags == 0b0011 {
            guard data.count >= offset + 4 else { return nil }
            offset += 4
        }

        guard data.count >= offset + 4 else { return nil }
        let payloadSize = readUInt32BE(data: data, offset: offset)
        offset += 4

        let payloadEnd = offset + Int(payloadSize)
        guard payloadEnd <= data.count else { return nil }

        let payload = data.subdata(in: offset..<payloadEnd)
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }

        // Check status code
        if let statusCode = json["status_code"] as? Int, statusCode != 20000000 {
            let msg = json["message"] as? String ?? "Unknown"
            TNTLog.error("[VolcASR] API error: \(statusCode) - \(msg)")
            return nil
        }

        // Extract result text
        if let result = json["result"] as? [String: Any] {
            if let text = result["text"] as? String, !text.isEmpty {
                return text
            }
            // Fallback: join utterance texts
            if let utterances = result["utterances"] as? [[String: Any]] {
                let texts = utterances.compactMap { $0["text"] as? String }
                let joined = texts.joined()
                if !joined.isEmpty { return joined }
            }
        }

        return ""
    }

    private func parseErrorResponse(data: Data) {
        guard data.count >= 12 else { return }
        let errorCode = readUInt32BE(data: data, offset: 4)
        let errorSize = readUInt32BE(data: data, offset: 8)
        let errorEnd = min(12 + Int(errorSize), data.count)
        let errorMsg = String(decoding: data.subdata(in: 12..<errorEnd), as: UTF8.self)
        TNTLog.error("[VolcASR] Server error code=\(errorCode): \(errorMsg)")
    }

    private func readUInt32BE(data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
        (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) |
        UInt32(data[offset + 3])
    }
}
