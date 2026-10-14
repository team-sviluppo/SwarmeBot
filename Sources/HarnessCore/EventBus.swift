// Fan-in event bus — `server/harness/bus.ts`.
//
// Every adapter's events merge here, are stamped with their instance, teed
// to the per-thread canonical NDJSON log (redacted: these files get pasted
// into bug reports), and delivered to subscribers — the SSE hub and the fold.
import Foundation

@MainActor
public final class EventBus {
    private var listeners: [(id: UUID, listener: RuntimeEventListener)] = []
    private var detachers: [() -> Void] = []
    private let eventsDir: URL

    public init(eventsDir: URL) {
        self.eventsDir = eventsDir
    }

    public func attach(_ instance: ProviderInstance) {
        let kind = instance.driverKind
        let instanceId = instance.instanceId
        let off = instance.adapter.onEvent { [weak self] event in
            // an adapter may only speak for its own driver kind
            guard event.provider == kind else {
                FileHandle.standardError.write(Data("bus: dropped cross-driver event from \(instanceId)\n".utf8))
                return
            }
            var stamped = event
            stamped.providerInstanceId = instanceId
            self?.publish(stamped)
        }
        detachers.append(off)
    }

    public func publish(_ event: RuntimeEvent) {
        FileIO.appendLine(
            Redact.json(event.json).serialized(),
            to: eventsDir.appendingPathComponent("\(event.threadId).ndjson")
        )
        // registration order matters: the fold runs before the queue drain,
        // exactly as in the Node engine
        for entry in listeners { entry.listener(event) }
    }

    @discardableResult
    public func subscribe(_ listener: @escaping RuntimeEventListener) -> () -> Void {
        let id = UUID()
        listeners.append((id, listener))
        return { [weak self] in
            MainActor.assumeIsolated { self?.listeners.removeAll { $0.id == id } }
        }
    }

    public func detachAll() {
        detachers.forEach { $0() }
        detachers.removeAll()
    }
}
