// A phone bot's turn that goes on with the app in the background. iOS
// suspends an app about half a minute after it leaves the screen, and a
// reply streaming from an endpoint then breaks with a network error. A
// continued processing task (iOS 26), asked when the turn starts — only an
// app on screen may ask — keeps the app running until the reply is complete
// and shows the turn in the system's progress UI, where it can be stopped.
//
// Not for Gemma: its GPU work needs another entitlement in the background.
import BackgroundTasks
import Foundation
import OSLog

private let log = Logger(subsystem: "it.hextra.swarmebot", category: "background")

@MainActor
final class TurnInBackground {
    /// Asked, not started yet: the launch handler finds its turn here.
    private static var waiting: [String: TurnInBackground] = [:]
    /// The progress the system shows; a turn has no known length, so it
    /// creeps towards the end and is completed when the reply is.
    private static let total: Int64 = 1_000_000

    private let identifier: String
    private let onExpire: () -> Void
    private var task: BGContinuedProcessingTask?
    private var heartbeat: Task<Void, Never>?
    private var done = false

    private init(identifier: String, onExpire: @escaping () -> Void) {
        self.identifier = identifier
        self.onExpire = onExpire
    }

    /// Nil when iOS doesn't grant it: the turn runs as before, until the app is suspended.
    /// `onExpire` stops the turn: the user stopped it from the system UI, or iOS needed the resources.
    static func begin(title: String, subtitle: String, onExpire: @escaping () -> Void) -> TurnInBackground? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }
        // permitted as `<bundle id>.turn.*` (project.yml); one identifier per turn, registered once
        let identifier = "\(bundle).turn.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { started(identifier, task) }
        }
        guard registered else {
            log.error("continued processing not permitted for \(identifier, privacy: .public)")
            return nil
        }
        let turn = TurnInBackground(identifier: identifier, onExpire: onExpire)
        waiting[identifier] = turn
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // a turn that can't go on now is not worth starting later
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("continued processing refused: \(error.localizedDescription, privacy: .public)")
            waiting[identifier] = nil
            return nil
        }
        return turn
    }

    private static func started(_ identifier: String, _ task: BGTask) {
        let turn = waiting.removeValue(forKey: identifier)
        guard let task = task as? BGContinuedProcessingTask, let turn, !turn.done else {
            task.setTaskCompleted(success: true)
            return
        }
        turn.attach(task)
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = Self.total
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expired() }
        }
        // a model thinking, or a tool running, streams nothing for a while:
        // the turn is still alive, and a task that looks stalled is expired
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.advance()
            }
        }
    }

    /// Something happened in the turn (a piece of the reply, a tool).
    func advance() {
        guard let progress = task?.progress, !done else { return }
        let left = Self.total - 1 - progress.completedUnitCount
        guard left > 0 else { return }
        progress.completedUnitCount += max(1, left / 200)
    }

    /// The turn is over, however it ended.
    func end(success: Bool = true) {
        guard !done else { return }
        done = true
        heartbeat?.cancel()
        heartbeat = nil
        if let task {
            task.progress.completedUnitCount = Self.total
            task.setTaskCompleted(success: success)
            self.task = nil
        } else {
            Self.waiting[identifier] = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    private func expired() {
        guard !done else { return }
        log.info("continued processing expired: stopping the turn")
        onExpire()
        end(success: false)
    }
}
