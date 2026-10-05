import Foundation

/// The KV-keeping session the meeting reader drives (Android `ReaderLlm`): one growing
/// conversation, extended by `append` (prefill only) and `generateContinue` (its tokens join the
/// sequence), restarted by `reset`. Not thread-safe: the reader lane serializes every call.
protocol ReaderLlm: AnyObject {
    /// Token ids of `text` without BOS; `special` parses template pieces (`<|turn>` …).
    func tokenize(_ text: String, special: Bool) -> [Int]
    /// Prefill `tokens` onto the cache. Returns the new sequence length, or -1 on failure.
    func append(_ tokens: [Int]) -> Int
    /// Decode until `stop` (kept in the sequence and at the end of the returned text), end of
    /// generation or `maxTokens`; `onToken` receives streamed pieces.
    func generateContinue(maxTokens: Int, stop: String, temp: Float, onToken: (String) -> Void) -> String
    var seqLength: Int { get }
    func reset()
}

enum AgentState { case starting, listening, reading, restarting, summarizing, done }
enum DropReason { case parse, citation, cap, duplicate }

/// What the agent is doing, for the live Agent panel.
enum AgentEvent {
    case state(AgentState, window: Int = 0, ctxTokens: Int = 0, notes: Int = 0, windowMax: Int = 0, ctxMax: Int = 0)
    case fed(window: Int, what: String, tokens: Int, ms: Int, ctxTokens: Int)
    case turnToken(window: Int, piece: String)
    case turnDone(window: Int, reply: String, kept: Int, ms: Int)
    case noteKept(Note)
    case noteDropped(window: Int, line: String, reason: DropReason)
    case restart(count: Int, ctxBefore: Int, ctxAfter: Int)
}

struct ReaderError: Error, CustomStringConvertible { let description: String }
