// The harness side of routines and webhooks: the RoutineManager and the
// WebhookManager wired to the store and to turns, as in `server/index.ts`.
import Foundation

extension Harness {
    func botState(_ botId: String) -> String {
        guard let bot = store.bot(botId) else { return "missing" }
        return Store.isBusy(bot) ? "busy" : "ready"
    }

    /// The engine a run's interrupt must reach: the cloud runner, or the bot's own.
    func automationInstance(botId: String, runOn: String) -> ProviderInstance? {
        if runOn == "cloud" { return fleet.instances().first { $0.driverKind == "boxAgent" } }
        return store.bot(botId).flatMap { fleet.get(ModelSelection(json: $0["modelSelection"]).instanceId) }
    }

    func startAutomations() {
        routines = RoutineManager(file: paths.root.appendingPathComponent("routines.json"), host: .init(
            emit: { [weak self] payload in self?.broadcast(payload) },
            botState: { [weak self] in self?.botState($0) ?? "missing" },
            createTask: { [weak self] botId, title, activate in
                guard let self, let task = self.store.createTask(botId, title: title, activate: activate) else { return nil }
                if let bot = self.store.bot(botId) { self.broadcast(["kind": "bot", "bot": .object(self.wireBot(bot))]) }
                return task["threadId"]?.string
            },
            startTurn: { [weak self] botId, threadId, prompt, runOn, trigger, onDispatchError in
                try self?.startTurn(botId: botId, text: prompt, threadId: threadId, options: TurnOptions(
                    onDispatchError: onDispatchError, runOn: runOn, automationSource: trigger))
            },
            interruptTurn: { [weak self] botId, threadId, runOn in
                let instance = self?.automationInstance(botId: botId, runOn: runOn)
                Task { await instance?.adapter.interruptTurn(threadId: threadId) }
            }
        ))
        routines.start()
        // every delivery joins the routine queue: ordered behind a busy bot, same receipts
        webhooks = WebhookManager(file: paths.root.appendingPathComponent("webhooks.json"), host: .init(
            emit: { [weak self] payload in self?.broadcast(payload) },
            botState: { [weak self] in self?.botState($0) ?? "missing" },
            enqueue: { [weak self] webhookId, name, prompt, botId, runOn, deliveryId, receivedAt in
                guard let self else { throw HTTPError(500, "harness gone") }
                return try self.routines.enqueueWebhook(webhookId: webhookId, webhookName: name, prompt: prompt, botId: botId,
                                                        runOn: runOn, deliveryId: deliveryId, receivedAt: receivedAt)
            },
            cancelQueued: { [weak self] webhookId, message in self?.routines.cancelQueuedWebhook(webhookId, message: message) },
            pendingRuns: { [weak self] in self?.routines.activeWebhookRunCount($0) ?? 0 }
        ))
    }
}
