// "Sposta su…" — a bot moved between this Mac's engine and a server (or the
// other way round, or between two servers): docs/plans/2026-10-25-copia-su-server.md.
//
// The app does it with the routes both engines already have; no engine is
// told about the other. What goes over is who the bot is: name, title,
// instructions, color, notifications and its picture. What stays behind is
// what belongs to an environment: model, skills, connectors, working folder,
// computer, permissions; they are set again by hand where the bot lands.
// Chats do not move.
//
// Automations do move: the bot's routines and webhooks are created on the
// target and then deleted on the source, so none runs twice. A webhook gets
// a new address and secret there (they belong to the engine that receives
// it), to give again to whoever calls it.
//
// Order: everything is created on the target first; if a step fails, what
// was created there is removed and the source is left as it was. Only then
// is the source touched.
import CompanionCore
import Foundation

public struct BotTransferResult: Sendable {
    public struct MovedWebhook: Sendable, Identifiable {
        public var name: String
        public var credential: WebhookCredential?
        public var id: String { name }
    }

    public var bot: Bot
    public var routines: [String]
    public var webhooks: [MovedWebhook]
    /// Source cleanups that failed after the bot was safely on the target.
    public var warnings: [String]
}

public enum BotTransfer {
    /// What the move would carry over, to show before it starts.
    public static func automations(of bot: Bot, on source: CompanionClient) async throws -> (routines: [Routine], webhooks: [WebhookTrigger]) {
        async let routines = source.routines().routines
        async let webhooks = source.webhooks().webhooks
        return try await (routines.filter { $0.botId == bot.id }, webhooks.filter { $0.botId == bot.id })
    }

    /// The identity of the bot, as a PATCH of the new one.
    static func identity(of bot: Bot) -> BotPatch {
        var patch = BotPatch(name: bot.name, title: bot.title, description: bot.description,
                             notifications: bot.notifications, color: bot.color)
        if let silhouette = bot.mascotSilhouette, !silhouette.isEmpty { patch.mascotSilhouette = silhouette }
        if let expression = bot.mascotExpression, !expression.isEmpty { patch.mascotExpression = expression }
        return patch
    }

    /// A routine for the new bot. A one-off whose time has passed would run
    /// at once on the target: it goes over switched off.
    static func routineInput(_ routine: Routine, botId: String, now: Date = Date()) -> RoutineInput {
        var enabled = routine.enabled
        if routine.schedule.type == "once", let at = routine.schedule.at, at < now.timeIntervalSince1970 * 1000 { enabled = false }
        var input = RoutineInput(name: routine.name, prompt: routine.prompt, botId: botId, enabled: enabled,
                                 schedule: routine.schedule, durationMinutes: routine.durationMinutes)
        input.runOn = routine.runOn ?? "maus"
        return input
    }

    static func webhookInput(_ webhook: WebhookTrigger, botId: String) -> WebhookInput {
        var input = WebhookInput(name: webhook.name, prompt: webhook.prompt, botId: botId, enabled: webhook.enabled,
                                 eventTypes: webhook.eventTypes ?? [])
        input.runOn = webhook.runOn ?? "maus"
        input.verificationPending = webhook.verificationPending
        return input
    }

    static func imageMime(_ name: String) -> String? {
        ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][
            (name as NSString).pathExtension.lowercased()]
    }

    /// The picture: SVG markup, or the raster fetched from the source's
    /// attachments; a sprite sheet keeps the row it showed.
    static func copyPicture(of bot: Bot, from source: CompanionClient, to target: CompanionClient, botId: String) async throws -> Bot? {
        let uploaded: Bot
        if let svg = bot.mascotAvatarSvg, !svg.isEmpty {
            uploaded = try await target.uploadAvatar(botId: botId, Data(svg.utf8), mime: "image/svg+xml")
        } else if let name = bot.mascotAvatarImage, !name.isEmpty, let mime = imageMime(name) {
            uploaded = try await target.uploadAvatar(botId: botId, try await source.attachment(named: name), mime: mime)
        } else {
            return nil
        }
        guard uploaded.mascotAvatarSheetRow != bot.mascotAvatarSheetRow else { return uploaded }
        var patch = BotPatch()
        patch.mascotAvatarSheetRow = bot.mascotAvatarSheetRow.map { Int($0) } ?? -1
        return try await target.patchBot(botId, patch)
    }

    /// Move `bot` from `source` to `target`. `deleteOriginal` then deletes it
    /// on the source, chats included; otherwise it stays there, without its automations.
    public static func move(_ bot: Bot, from source: CompanionClient, to target: CompanionClient,
                            deleteOriginal: Bool) async throws -> BotTransferResult {
        let (routines, webhooks) = try await automations(of: bot, on: source)

        // 1. everything on the target, undone if a step fails
        let created = try await target.createBot()
        var createdRoutines: [String] = []
        var createdWebhooks: [String] = []
        var moved: [BotTransferResult.MovedWebhook] = []
        let newBot: Bot
        do {
            let named = try await target.patchBot(created.id, identity(of: bot))
            newBot = try await copyPicture(of: bot, from: source, to: target, botId: created.id) ?? named
            for routine in routines {
                createdRoutines.append(try await target.createRoutine(routineInput(routine, botId: created.id)).id)
            }
            for webhook in webhooks {
                let made = try await target.createWebhook(webhookInput(webhook, botId: created.id))
                createdWebhooks.append(made.webhook.id)
                moved.append(.init(name: webhook.name, credential: made.credential))
            }
        } catch {
            for id in createdWebhooks { try? await target.deleteWebhook(id) }
            for id in createdRoutines { try? await target.deleteRoutine(id) }
            try? await target.deleteBot(created.id)
            throw error
        }

        // 2. the source: its automations go, so none runs twice
        var warnings: [String] = []
        for routine in routines {
            do { try await source.deleteRoutine(routine.id) } catch {
                warnings.append(tr("Routine %@ non eliminata dall'origine: %@", routine.name, error.localizedDescription))
            }
        }
        for webhook in webhooks {
            do { try await source.deleteWebhook(webhook.id) } catch {
                warnings.append(tr("Webhook %@ non eliminato dall'origine: %@", webhook.name, error.localizedDescription))
            }
        }
        if deleteOriginal {
            do { try await source.deleteBot(bot.id) } catch {
                warnings.append(tr("Il bot originale non è stato eliminato: %@", error.localizedDescription))
            }
        }
        return BotTransferResult(bot: newBot, routines: routines.map(\.name), webhooks: moved, warnings: warnings)
    }
}

extension AppModel {
    /// A client for an engine, shown or not.
    public func client(for choice: EngineChoice) -> CompanionClient? {
        choice == engineChoice ? client : peerClient(choice)
    }

    public func engineName(_ choice: EngineChoice) -> String {
        switch choice {
        case .local: return tr("Questo Mac")
        case let .remote(id): return remoteEngines.first { $0.id == id }?.name ?? id
        }
    }

    /// Every engine a bot of the shown one can move to.
    public var transferTargets: [EngineChoice] {
        var all: [EngineChoice] = remoteEngines.map { .remote($0.id) }
        if localPort != nil { all.insert(.local, at: 0) }
        return all.filter { $0 != engineChoice }
    }

    public func automationsToMove(_ bot: Bot) async throws -> (routines: [Routine], webhooks: [WebhookTrigger]) {
        guard let client else { throw APIError.transport(tr("Motore non raggiungibile")) }
        return try await BotTransfer.automations(of: bot, on: client)
    }

    /// Move a bot of the shown engine to `target`.
    public func move(_ bot: Bot, to target: EngineChoice, deleteOriginal: Bool) async throws -> BotTransferResult {
        guard let source = client, let destination = client(for: target) else { throw APIError.transport(tr("Motore non raggiungibile")) }
        let result = try await BotTransfer.move(bot, from: source, to: destination, deleteOriginal: deleteOriginal)
        if deleteOriginal, selection == .bot(bot.id) { selection = defaultSelection }
        state.webhooks.removeAll { $0.botId == bot.id }
        return result
    }
}
