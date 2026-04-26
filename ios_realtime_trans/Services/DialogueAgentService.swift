//
//  DialogueAgentService.swift
//  ios_realtime_trans
//
//  Google ADK dialogue agent client.
//

import Foundation

enum DialogueAgentMode: String, Codable {
    case realtime
    case consolidate
}

struct DialogueAgentFragment: Codable, Equatable {
    let id: String
    let text: String
    let isFinal: Bool
    let timestampMs: Int
    let confidence: Double?
}

struct DialogueAgentPreviousTurn: Codable, Equatable {
    let id: String
    let original: String
    let translation: String?
}

struct DialogueAgentPlayedTTS: Codable, Equatable {
    let text: String
}

struct DialogueAgentAudioHealth: Codable, Equatable {
    var repeatedNoiseCount: Int?
    var noValidSpeechMs: Int?
}

struct DialogueAgentRequest: Codable, Equatable {
    let agentMode: DialogueAgentMode
    let sourceLang: String
    let targetLang: String
    let fragments: [DialogueAgentFragment]
    let previousTurns: [DialogueAgentPreviousTurn]
    let playedTTS: [DialogueAgentPlayedTTS]
    let audioHealth: DialogueAgentAudioHealth
}

struct DialogueAgentTurn: Codable, Equatable {
    let id: String
    let sourceFragmentIds: [String]
    let original: String
    let detectedLang: String
    let translateTo: String
    let translation: String
    let status: String
}

struct DialogueAgentAction: Codable, Equatable {
    let type: String
    let targetIds: [String]
    let reason: String
}

struct DialogueAgentTTSPlanItem: Codable, Equatable {
    let id: String
    let sourceTurnId: String
    let text: String
    let languageCode: String
    let playPolicy: String
    let stable: Bool
    let revisionOf: String?
}

struct DialogueAgentAudioRecovery: Codable, Equatable {
    let shouldReset: Bool
    let reason: String
    let replayAudioFromMs: Int
    let dropTranscriptText: String
}

struct DialogueAgentInfo: Codable, Equatable {
    let enabled: Bool?
    let provider: String?
    let model: String?
    let mode: String?
    let latencyMs: Int?
}

struct DialogueAgentResponse: Codable, Equatable {
    let normalizedTurns: [DialogueAgentTurn]
    let actions: [DialogueAgentAction]
    let ttsPlan: [DialogueAgentTTSPlanItem]
    let audioRecovery: DialogueAgentAudioRecovery
    let confidence: Double
    let warnings: [String]
    let agent: DialogueAgentInfo?
}

enum DialogueAgentServiceError: Error {
    case invalidURL
    case invalidHTTPResponse
    case httpError(Int, Data)
}

final class DialogueAgentService {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func createPlan(
        serverURL: String,
        request: DialogueAgentRequest,
        timeout: TimeInterval? = nil
    ) async throws -> DialogueAgentResponse {
        guard let url = makeDialoguePlanURL(serverURL: serverURL) else {
            throw DialogueAgentServiceError.invalidURL
        }

        let body = try encoder.encode(request)
        let requestTimeout = timeout ?? (request.agentMode == .consolidate ? 35 : 15)
        let data: Data
        let statusCode: Int

        if url.scheme == "https" {
            (data, statusCode) = try await IPv4HTTPClient.shared.post(
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body,
                timeout: requestTimeout
            )
        } else {
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = body
            urlRequest.timeoutInterval = requestTimeout
            let (responseData, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw DialogueAgentServiceError.invalidHTTPResponse
            }
            data = responseData
            statusCode = http.statusCode
        }

        guard (200..<300).contains(statusCode) else {
            throw DialogueAgentServiceError.httpError(statusCode, data)
        }

        return try decoder.decode(DialogueAgentResponse.self, from: data)
    }

    private func makeDialoguePlanURL(serverURL: String) -> URL? {
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

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value += "/agent/dialogue-plan"
        return URL(string: value)
    }
}
