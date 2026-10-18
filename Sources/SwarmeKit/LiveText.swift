// Text being typed right now, kept out of `AppModel.state`.
//
// `@Observable` tracks `state` as one property: any write to it, however
// small, invalidates every view that read anything from it — the sidebar,
// the inspector, the whole transcript. Deltas arrive dozens of times a
// second, and the R1 benchmark measured what that costs: on a 5,000-message
// thread, 300 deltas took 23 s instead of 5. Folding them here instead means
// a delta re-renders the live bubble and nothing else.
import CompanionCore
import Foundation
import Observation

@MainActor
@Observable
public final class LiveText {
    public private(set) var text: [String: String] = [:]
    public private(set) var reasoning: [String: String] = [:]

    public init() {}

    /// Same rules as `CompanionState.apply(runtime:)`.
    public func apply(_ event: RuntimeEvent) {
        switch event.type {
        case "content.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            switch event.streamKind {
            case "assistant_text": text[event.threadId, default: ""] += delta
            case "reasoning_text": reasoning[event.threadId, default: ""] += delta
            default: break
            }
        case "turn.completed", "turn.failed", "turn.aborted":
            clear(event.threadId)
        default:
            break
        }
    }

    public func append(_ delta: String, to threadId: String) {
        text[threadId, default: ""] += delta
    }

    /// Everything, when the app switches to another engine.
    public func clearAll() {
        text = [:]
        reasoning = [:]
    }

    public func clear(_ threadId: String) {
        if text[threadId] != nil { text.removeValue(forKey: threadId) }
        if reasoning[threadId] != nil { reasoning.removeValue(forKey: threadId) }
    }
}
