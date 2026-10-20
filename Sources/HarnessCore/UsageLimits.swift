// The subscription's session window, as the CLIs report it (Claude's
// `rate_limit_event`). It belongs to the account behind an instance, not to a
// thread, so it is kept per instance: `GET /api/instances` carries the last
// one as `usageLimit`, and a `usage-limit` frame announces each change.
// In memory only: after a restart it is unknown until the next turn.
import Foundation

extension Harness {
    func noteUsageLimit(_ instanceId: InstanceID?, window: String, utilization: Double, resetsAt: Double?) {
        guard let instanceId, utilization.isFinite else { return }
        var limit: JSONObject = ["window": .string(window), "utilization": .number(utilization)]
        if let resetsAt, resetsAt.isFinite { limit["resetsAt"] = .number(resetsAt) }
        let value = JSON.object(limit)
        guard usageLimits[instanceId] != value else { return }
        usageLimits[instanceId] = value
        hub.broadcast(["kind": "usage-limit", "instanceId": .string(instanceId), "usageLimit": value])
    }

    /// `GET /api/instances` rows with the last known window added.
    func withUsageLimits(_ rows: [JSON]) -> [JSON] {
        rows.map { row in
            guard var object = row.object, let id = object["instanceId"]?.string, let limit = usageLimits[id] else { return row }
            object["usageLimit"] = limit
            return .object(object)
        }
    }
}
