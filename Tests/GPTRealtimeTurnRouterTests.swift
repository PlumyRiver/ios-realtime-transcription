import Foundation

@main
enum GPTRealtimeTurnRouterTests {
    static func main() {
        let oldMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var router = GPTRealtimeTurnRouter()

        precondition(router.resolve(responseId: "old-response", sourceMessageId: oldMessageId) == oldMessageId)
        precondition(router.resolve(responseId: "new-response", sourceMessageId: newMessageId) == newMessageId)
        precondition(
            router.resolve(responseId: "old-response", sourceMessageId: newMessageId) == oldMessageId,
            "A late old response must not be redirected to the newest bubble"
        )

        precondition(router.resolve(responseId: "delayed-response", sourceMessageId: nil) == nil)
        precondition(router.resolve(responseId: "delayed-response", sourceMessageId: oldMessageId) == oldMessageId)

        router.reset()
        precondition(router.resolve(responseId: "old-response", sourceMessageId: newMessageId) == newMessageId)
        print("GPT Realtime turn router tests passed")
    }
}
