//
//  BackgroundLectureSTTService.swift
//  ios_realtime_trans
//
//  Batches Silero-filtered 16 kHz mono PCM and sends it to GPT Transcribe.
//

import Foundation
import FirebaseAuth

struct BackgroundLectureTranscript: Sendable {
    let text: String
    let language: String?
    let audioDurationMs: Int
    let latencyMs: Int
    let costUSD: Double
}

struct BackgroundLecturePromptContext: Sendable {
    let prompt: String
    let keywords: [String]
    let cacheHit: Bool
}

enum BackgroundLectureSTTProvider: String, CaseIterable, Identifiable {
    case gpt4oBatch = "gpt-4o-transcribe"
    case elevenLabsBatch = "elevenlabs-batch"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4oBatch: return "GPT-4o"
        case .elevenLabsBatch: return "ElevenLabs Batch"
        }
    }

    var detail: String {
        switch self {
        case .gpt4oBatch: return "高品質 · 約 $0.006/分鐘"
        case .elevenLabsBatch: return "Scribe v2 · 約 $0.22/小時"
        }
    }
}

enum BackgroundLectureSTTError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case httpError(Int, String)
    case emptyPromptContext

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "無效的伺服器網址"
        case .invalidResponse:
            return "伺服器回應格式錯誤"
        case .httpError(let status, let message):
            return "背景轉錄失敗（\(status)）：\(message)"
        case .emptyPromptContext:
            return "找不到可用的提示詞內容"
        }
    }
}

final class BackgroundLectureSTTService: @unchecked Sendable {
    private struct Configuration: Sendable {
        let serverURL: String
        let provider: BackgroundLectureSTTProvider
        let sourceLanguages: [String]
        let prompt: String
        let batchDurationSeconds: Int

        var primaryLanguage: String {
            sourceLanguages.first ?? "auto"
        }

        var languageMode: String {
            if sourceLanguages.count > 1 { return "multi" }
            if sourceLanguages.count == 1 { return "single" }
            return "auto"
        }
    }

    private struct Batch: Sendable {
        let id: UUID
        let pcm: Data

        var durationMs: Int {
            Int((Double(pcm.count) / 32_000.0) * 1_000.0)
        }
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
        let languageCode: String?
        let detectedLanguage: String?
        let latencyMs: Int?
        let sttCostUSD: Double?
        let provider: String?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case text
            case languageCode = "language_code"
            case detectedLanguage = "detected_language"
            case latencyMs
            case sttCostUSD
            case provider
            case model
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String?
    }

    private struct ResearchResponse: Decodable {
        struct Context: Decodable {
            let prompt: String?
            let keywords: [String]?
        }

        let context: Context?
        let cacheHit: Bool?
    }

    var onTranscript: ((BackgroundLectureTranscript) -> Void)?
    var onError: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.kaijiang.lecture-stt", qos: .utility)
    private var configuration: Configuration?
    private var pcmBuffer = Data()
    private var pendingBatches: [Batch] = []
    private var isUploading = false
    private var isRunning = false
    private var stopCompletions: [() -> Void] = []

    private let bytesPerSecond = 16_000 * 2
    private let minimumBatchBytes = 16_000 * 2

    func start(
        serverURL: String,
        provider: BackgroundLectureSTTProvider,
        sourceLanguages: [String],
        prompt: String,
        batchDurationSeconds: Int
    ) {
        let normalizedLanguages = sourceLanguages.reduce(into: [String]()) { result, language in
            let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, normalized != "auto", !result.contains(normalized) else { return }
            result.append(normalized)
        }
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.configuration = Configuration(
                serverURL: serverURL,
                provider: provider,
                sourceLanguages: normalizedLanguages,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                batchDurationSeconds: min(max(batchDurationSeconds, 5), 30)
            )
            self.pcmBuffer.removeAll(keepingCapacity: true)
            self.pendingBatches.removeAll()
            self.stopCompletions.removeAll()
            self.isUploading = false
            self.isRunning = true
        }
    }

    func appendPCM(_ data: Data) {
        guard !data.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self, self.isRunning, let configuration = self.configuration else { return }
            self.pcmBuffer.append(data)

            let maximumBatchBytes = configuration.batchDurationSeconds * self.bytesPerSecond
            while self.pcmBuffer.count >= maximumBatchBytes {
                let pcm = self.pcmBuffer.prefix(maximumBatchBytes)
                self.pcmBuffer.removeFirst(maximumBatchBytes)
                self.pendingBatches.append(Batch(id: UUID(), pcm: Data(pcm)))
            }
            self.pumpUploadsIfNeeded()
        }
    }

    /// Flushes a speech turn after Silero reports a real silence boundary.
    func finishUtterance() {
        stateQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.enqueueBufferedSpeechIfLongEnough(force: false)
            self.pumpUploadsIfNeeded()
        }
    }

    /// Stops accepting PCM but waits until the final short tail has been uploaded.
    func stopAndFlush(completion: @escaping () -> Void) {
        stateQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            self.isRunning = false
            self.enqueueBufferedSpeechIfLongEnough(force: true)
            self.stopCompletions.append(completion)
            self.pumpUploadsIfNeeded()
            self.finishStopIfPossible()
        }
    }

    func researchPrompt(
        serverURL: String,
        topic: String,
        sourceLanguage: String,
        existingPrompt: String
    ) async throws -> BackgroundLecturePromptContext {
        guard let url = makeURL(serverURL: serverURL, path: "/ios/lecture/context") else {
            throw BackgroundLectureSTTError.invalidServerURL
        }

        let requestBody: [String: Any] = [
            "topic": topic,
            "sourceLanguage": sourceLanguage,
            "existingPrompt": existingPrompt
        ]
        let body = try JSONSerialization.data(withJSONObject: requestBody)
        var headers = ["Content-Type": "application/json"]
        if let token = await currentFirebaseIDToken() {
            headers["Authorization"] = "Bearer \(token)"
        }

        let (data, status) = try await IPv4HTTPClient.shared.post(
            url: url,
            headers: headers,
            body: body,
            timeout: 40
        )
        guard (200..<300).contains(status) else {
            throw BackgroundLectureSTTError.httpError(status, decodeErrorMessage(data))
        }

        let response = try JSONDecoder().decode(ResearchResponse.self, from: data)
        let prompt = response.context?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keywords = response.context?.keywords ?? []
        guard !prompt.isEmpty || !keywords.isEmpty else {
            throw BackgroundLectureSTTError.emptyPromptContext
        }
        return BackgroundLecturePromptContext(
            prompt: prompt,
            keywords: keywords,
            cacheHit: response.cacheHit ?? false
        )
    }

    private func enqueueBufferedSpeechIfLongEnough(force: Bool) {
        guard !pcmBuffer.isEmpty else { return }
        guard force || pcmBuffer.count >= minimumBatchBytes else { return }
        pendingBatches.append(Batch(id: UUID(), pcm: pcmBuffer))
        pcmBuffer.removeAll(keepingCapacity: true)
    }

    private func pumpUploadsIfNeeded() {
        guard !isUploading, let configuration, !pendingBatches.isEmpty else { return }
        isUploading = true
        let batch = pendingBatches.removeFirst()
        publishProcessing(true)

        Task { [weak self] in
            guard let self else { return }
            let result: Result<BackgroundLectureTranscript?, Error>
            do {
                result = .success(try await self.uploadWithRetry(batch, configuration: configuration))
            } catch {
                result = .failure(error)
            }

            self.stateQueue.async { [weak self] in
                guard let self else { return }
                self.isUploading = false
                switch result {
                case .success(let transcript):
                    if let transcript, !transcript.text.isEmpty {
                        self.publishTranscript(transcript)
                    }
                case .failure(let error):
                    self.publishError(error.localizedDescription)
                }
                self.pumpUploadsIfNeeded()
                if !self.isUploading && self.pendingBatches.isEmpty {
                    self.publishProcessing(false)
                }
                self.finishStopIfPossible()
            }
        }
    }

    private func finishStopIfPossible() {
        guard !isRunning, !isUploading, pendingBatches.isEmpty else { return }
        publishProcessing(false)
        let completions = stopCompletions
        stopCompletions.removeAll()
        configuration = nil
        for completion in completions {
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func uploadWithRetry(
        _ batch: Batch,
        configuration: Configuration
    ) async throws -> BackgroundLectureTranscript? {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                return try await upload(batch, configuration: configuration)
            } catch let error as BackgroundLectureSTTError {
                lastError = error
                if case .httpError(let status, _) = error, status != 429 && status < 500 {
                    throw error
                }
            } catch {
                lastError = error
            }

            if attempt == 0 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? BackgroundLectureSTTError.invalidResponse
    }

    private func upload(
        _ batch: Batch,
        configuration: Configuration
    ) async throws -> BackgroundLectureTranscript? {
        guard let url = makeURL(
            serverURL: configuration.serverURL,
            path: "/ios/lecture/transcribe",
            queryItems: [
                URLQueryItem(name: "sourceLang", value: configuration.primaryLanguage),
                URLQueryItem(name: "provider", value: configuration.provider.rawValue),
                URLQueryItem(name: "sttLanguageMode", value: configuration.languageMode),
                URLQueryItem(name: "filename", value: "lecture-\(batch.id.uuidString).wav"),
                URLQueryItem(name: "originalDurationMs", value: String(batch.durationMs)),
                URLQueryItem(name: "requestId", value: batch.id.uuidString)
            ]
        ) else {
            throw BackgroundLectureSTTError.invalidServerURL
        }

        let context: [String: Any] = [
            "sttPrompt": configuration.prompt,
            "sttKeywords": Self.extractKeywords(from: configuration.prompt),
            "sttLanguageMode": configuration.languageMode,
            "sourceLanguageHints": configuration.sourceLanguages
        ]
        let contextData = try JSONSerialization.data(withJSONObject: context)
        let contextBase64 = contextData.base64EncodedString()
        let headerChunks = contextBase64.chunked(maxLength: 1_500)

        var headers = [
            "Content-Type": "audio/wav",
            "x-lecture-stt-context-count": String(headerChunks.count)
        ]
        for (index, chunk) in headerChunks.enumerated() {
            headers["x-lecture-stt-context-\(index)"] = chunk
        }
        if let token = await currentFirebaseIDToken() {
            headers["Authorization"] = "Bearer \(token)"
        }

        let (data, status) = try await IPv4HTTPClient.shared.post(
            url: url,
            headers: headers,
            body: Self.makeWAV(fromPCM16: batch.pcm),
            timeout: 45
        )
        guard (200..<300).contains(status) else {
            throw BackgroundLectureSTTError.httpError(status, decodeErrorMessage(data))
        }

        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return BackgroundLectureTranscript(
            text: text,
            language: response.detectedLanguage ?? response.languageCode,
            audioDurationMs: batch.durationMs,
            latencyMs: response.latencyMs ?? 0,
            costUSD: response.sttCostUSD ?? 0
        )
    }

    private func makeURL(
        serverURL: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("ws://") {
            value = "http://" + value.dropFirst(5)
        } else if value.hasPrefix("wss://") {
            value = "https://" + value.dropFirst(6)
        } else if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            let isLocal = value.contains("localhost") || value.contains("127.0.0.1") || value.contains("192.168.")
            value = "\(isLocal ? "http" : "https")://\(value)"
        }

        guard var components = URLComponents(string: value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            return nil
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func currentFirebaseIDToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return await withCheckedContinuation { continuation in
            user.getIDTokenForcingRefresh(false) { token, _ in
                continuation.resume(returning: token)
            }
        }
    }

    private func decodeErrorMessage(_ data: Data) -> String {
        if let response = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let error = response.error,
           !error.isEmpty {
            return error
        }
        return String(data: data, encoding: .utf8)?.prefix(300).description ?? "未知錯誤"
    }

    private func publishTranscript(_ transcript: BackgroundLectureTranscript) {
        guard let onTranscript else { return }
        DispatchQueue.main.async {
            onTranscript(transcript)
        }
    }

    private func publishError(_ message: String) {
        guard let onError else { return }
        DispatchQueue.main.async {
            onError(message)
        }
    }

    private func publishProcessing(_ processing: Bool) {
        guard let onProcessingChanged else { return }
        DispatchQueue.main.async {
            onProcessingChanged(processing)
        }
    }

    static func makeWAV(fromPCM16 pcm: Data, sampleRate: UInt32 = 16_000) -> Data {
        let dataSize = UInt32(clamping: pcm.count)
        var wav = Data(capacity: 44 + pcm.count)
        wav.append("RIFF".data(using: .ascii)!)
        wav.appendLittleEndian(UInt32(36) + dataSize)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(sampleRate)
        wav.appendLittleEndian(sampleRate * 2)
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.append("data".data(using: .ascii)!)
        wav.appendLittleEndian(dataSize)
        wav.append(pcm)
        return wav
    }

    static func extractKeywords(from prompt: String) -> [String] {
        let markers = ["重點詞：", "關鍵詞：", "Keywords:", "Keyterms:"]
        guard let marker = markers.compactMap({ prompt.range(of: $0, options: [.caseInsensitive, .backwards]) }).max(by: { $0.lowerBound < $1.lowerBound }) else {
            return []
        }
        let suffix = prompt[marker.upperBound...]
        var seen = Set<String>()
        return suffix
            .components(separatedBy: CharacterSet(charactersIn: "、,，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { keyword in
                guard !keyword.isEmpty, keyword.count <= 49 else { return false }
                return seen.insert(keyword.lowercased()).inserted
            }
            .prefix(100)
            .map { $0 }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private extension String {
    func chunked(maxLength: Int) -> [String] {
        guard maxLength > 0, !isEmpty else { return [] }
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: maxLength, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}
