import Foundation

/// Pins every Realtime response to the source bubble selected by its first
/// authoritative source item. Later turns cannot redirect an in-flight response.
struct GPTRealtimeTurnRouter {
    private var sourceMessageIdByResponse: [String: UUID] = [:]

    mutating func resolve(responseId: String, sourceMessageId: UUID?) -> UUID? {
        let responseId = responseId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !responseId.isEmpty, let existing = sourceMessageIdByResponse[responseId] {
            return existing
        }
        guard let sourceMessageId else { return nil }
        if !responseId.isEmpty {
            sourceMessageIdByResponse[responseId] = sourceMessageId
        }
        return sourceMessageId
    }

    mutating func reset() {
        sourceMessageIdByResponse.removeAll()
    }
}
