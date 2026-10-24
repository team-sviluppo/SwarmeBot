// The phone's own tools for the phone's bots: calendar, reminders, contacts,
// alarms. A bot turns them on by group; Gemma and endpoints get them through
// ToolBox as OpenAI tools, Apple's model as Foundation Models tools
// (AppleDriver). Whatever writes asks the user first. Model-facing text stays
// English, like the engine's.
import AgentCore
import AlarmKit
import Contacts
import EventKit
import Foundation
import Observation
import SwiftUI

enum PhoneToolGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case calendar, reminders, contacts, alarms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return tr("Calendario")
        case .reminders: return tr("Promemoria")
        case .contacts: return tr("Rubrica")
        case .alarms: return tr("Sveglie e timer")
        }
    }

    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .alarms: return "alarm"
        }
    }
}

/// One tool: what the model sees. Parameters are strings or integers, so the
/// same list makes a JSON schema and a Foundation Models schema.
struct PhoneTool: Sendable {
    struct Parameter: Sendable {
        var name: String
        var description: String
        var integer = false
        var required = true
    }

    let group: PhoneToolGroup
    let name: String
    let description: String
    let parameters: [Parameter]

    var inputSchema: JSON {
        var properties = JSONObject()
        for parameter in parameters {
            properties[parameter.name] = ["type": .string(parameter.integer ? "integer" : "string"), "description": .string(parameter.description)]
        }
        return ["type": "object", "properties": .object(properties),
                "required": .array(parameters.filter(\.required).map { .string($0.name) })]
    }

    // descriptions are short: Apple's model has about 4,000 tokens for everything
    static let all: [PhoneTool] = [
        PhoneTool(group: .calendar, name: "calendar_events", description: "List the calendar events of one or more days.", parameters: [
            Parameter(name: "from", description: "First day, YYYY-MM-DD; today if missing", required: false),
            Parameter(name: "days", description: "How many days, 1 to 31; 1 if missing", integer: true, required: false),
        ]),
        PhoneTool(group: .calendar, name: "calendar_add", description: "Add an event to the calendar.", parameters: [
            Parameter(name: "title", description: "What the event is"),
            Parameter(name: "start", description: "Local start, YYYY-MM-DDTHH:MM, or YYYY-MM-DD for all day"),
            Parameter(name: "minutes", description: "Duration in minutes; 60 if missing", integer: true, required: false),
            Parameter(name: "location", description: "Where", required: false),
        ]),
        PhoneTool(group: .reminders, name: "reminders_list", description: "List the reminders not done yet.", parameters: []),
        PhoneTool(group: .reminders, name: "reminder_add", description: "Add a reminder.", parameters: [
            Parameter(name: "title", description: "What to remember"),
            Parameter(name: "due", description: "Local due time, YYYY-MM-DDTHH:MM or YYYY-MM-DD", required: false),
        ]),
        PhoneTool(group: .contacts, name: "contacts_search", description: "Find contacts by name or phone number: their phones and emails.", parameters: [
            Parameter(name: "query", description: "A name, a surname or a phone number"),
        ]),
        PhoneTool(group: .alarms, name: "alarm_set", description: "Set an alarm.", parameters: [
            Parameter(name: "time", description: "Local time HH:MM (next one), or YYYY-MM-DDTHH:MM"),
            Parameter(name: "label", description: "What the alarm is for", required: false),
        ]),
        PhoneTool(group: .alarms, name: "timer_set", description: "Start a timer that rings after some minutes.", parameters: [
            Parameter(name: "minutes", description: "Minutes from now", integer: true),
            Parameter(name: "label", description: "What the timer is for", required: false),
        ]),
    ]

    static func tools(_ groups: [PhoneToolGroup]) -> [PhoneTool] { all.filter { groups.contains($0.group) } }
}

/// A write the user has to allow, shown by RootView as an alert.
struct PhoneConfirmation: Identifiable {
    let id: String
    let title: String
    let detail: String
    fileprivate let answer: CheckedContinuation<Bool, Never>
}

private struct PhoneAlarmMetadata: AlarmMetadata {}

@MainActor
@Observable
final class PhoneTools {
    /// The connector id phone tools carry in a `ChatTool`.
    static let connectorId = "phone"

    private(set) var pending: PhoneConfirmation?
    @ObservationIgnored private let events = EKEventStore()

    /// "Now" for the model: tools take local times, and it has to know today.
    static func now(_ date: Date = Date()) -> String {
        "Now is \(stamp(date, time: true)) (\(TimeZone.current.identifier))."
    }

    // MARK: Confirmation

    /// Asks the user, one question at a time; a stopped turn answers no.
    func confirm(_ title: String, _ detail: String) async -> Bool {
        while pending != nil {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return false }
        }
        let id = newId()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { return continuation.resume(returning: false) }
                pending = PhoneConfirmation(id: id, title: title, detail: detail, answer: continuation)
            }
        } onCancel: {
            Task { @MainActor in self.answer(id, false) }
        }
    }

    func answer(_ id: String, _ allowed: Bool) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.answer.resume(returning: allowed)
    }

    // MARK: Calls

    func call(_ name: String, arguments: JSON) async -> ToolBox.Result {
        do {
            switch name {
            case "calendar_events": return try await calendarEvents(arguments)
            case "calendar_add": return try await calendarAdd(arguments)
            case "reminders_list": return try await remindersList()
            case "reminder_add": return try await reminderAdd(arguments)
            case "contacts_search": return try await contactsSearch(arguments)
            case "alarm_set": return try await alarmSet(arguments)
            case "timer_set": return try await timerSet(arguments)
            default: return ToolBox.Result(text: "Unknown tool \(name).", ok: false)
            }
        } catch let error as Refusal {
            return ToolBox.Result(text: error.message, ok: false)
        } catch {
            return ToolBox.Result(text: "\(name) failed: \(error.localizedDescription)", ok: false)
        }
    }

    private struct Refusal: Error {
        let message: String
    }

    private static let declined = ToolBox.Result(text: "The user declined: nothing was done. Do not retry unless asked.", ok: false)

    private static func denied(_ what: String) -> Refusal {
        Refusal(message: "SwarmeBot may not use the \(what): the user can allow it in Settings › SwarmeBot.")
    }

    private static func string(_ arguments: JSON, _ key: String) -> String? {
        let value = arguments[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func integer(_ arguments: JSON, _ key: String) -> Int? {
        if let number = arguments[key]?.int { return number }
        return string(arguments, key).flatMap { Int($0) }
    }

    private static func required(_ arguments: JSON, _ key: String) throws -> String {
        guard let value = string(arguments, key) else { throw Refusal(message: "Missing \"\(key)\".") }
        return value
    }

    private static func when(_ arguments: JSON, _ key: String) throws -> (date: Date, time: Bool)? {
        guard let text = string(arguments, key) else { return nil }
        guard let parsed = parseDate(text) else { throw Refusal(message: "\"\(key)\" is not YYYY-MM-DD or YYYY-MM-DDTHH:MM: \(text)") }
        return parsed
    }

    // MARK: Calendar

    private func calendarAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        guard (try? await events.requestFullAccessToEvents()) == true else { throw Self.denied("calendar") }
    }

    private func calendarEvents(_ arguments: JSON) async throws -> ToolBox.Result {
        try await calendarAccess()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: try Self.when(arguments, "from")?.date ?? Date())
        let days = min(31, max(1, Self.integer(arguments, "days") ?? 1))
        let end = calendar.date(byAdding: .day, value: days, to: start) ?? start
        let found = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        guard !found.isEmpty else { return ToolBox.Result(text: "No events.", ok: true) }
        let lines = found.prefix(40).map { event in
            var line = event.isAllDay ? "\(Self.stamp(event.startDate, time: false)) all day"
                : "\(Self.stamp(event.startDate, time: true))–\(Self.clock(event.endDate))"
            line += " \(event.title ?? "")"
            if let location = event.location, !location.isEmpty { line += " @ \(location)" }
            return line
        }
        return ToolBox.Result(text: lines.joined(separator: "\n") + (found.count > 40 ? "\n(\(found.count - 40) more)" : ""), ok: true)
    }

    private func calendarAdd(_ arguments: JSON) async throws -> ToolBox.Result {
        let title = try Self.required(arguments, "title")
        guard let start = try Self.when(arguments, "start") else { throw Refusal(message: "Missing \"start\".") }
        let minutes = max(1, Self.integer(arguments, "minutes") ?? 60)
        let location = Self.string(arguments, "location")
        let end = start.date.addingTimeInterval(TimeInterval(minutes * 60))
        var detail = "\(title)\n" + (start.time
            ? start.date.appFormatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()) + " – " + end.appFormatted(.dateTime.hour().minute())
            : start.date.appFormatted(.dateTime.weekday(.wide).day().month(.wide)))
        if let location { detail += "\n\(location)" }
        guard await confirm(tr("Aggiungere l'appuntamento?"), detail) else { return Self.declined }
        try await calendarAccess()
        let event = EKEvent(eventStore: events)
        event.title = title
        event.location = location
        event.isAllDay = !start.time
        event.startDate = start.date
        event.endDate = start.time ? end : start.date
        guard let target = events.defaultCalendarForNewEvents else { throw Refusal(message: "There is no calendar to add events to.") }
        event.calendar = target
        try events.save(event, span: .thisEvent)
        return ToolBox.Result(text: "Added \"\(title)\" on \(Self.stamp(start.date, time: start.time)) to \(target.title).", ok: true)
    }

    // MARK: Reminders

    private func remindersAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return }
        guard (try? await events.requestFullAccessToReminders()) == true else { throw Self.denied("reminders") }
    }

    private func remindersList() async throws -> ToolBox.Result {
        try await remindersAccess()
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let lines: [String] = await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { found in
                let sorted = (found ?? []).sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                continuation.resume(returning: sorted.prefix(40).map { reminder in
                    var line = "- \(reminder.title ?? "")"
                    if let components = reminder.dueDateComponents, let due = Calendar.current.date(from: components) {
                        line += " (due \(Self.stamp(due, time: components.hour != nil)))"
                    }
                    return line + " [\(reminder.calendar?.title ?? "")]"
                })
            }
        }
        return ToolBox.Result(text: lines.isEmpty ? "No reminders to do." : lines.joined(separator: "\n"), ok: true)
    }

    private func reminderAdd(_ arguments: JSON) async throws -> ToolBox.Result {
        let title = try Self.required(arguments, "title")
        let due = try Self.when(arguments, "due")
        var detail = title
        if let due {
            detail += "\n" + due.date.appFormatted(due.time ? .dateTime.weekday(.wide).day().month(.wide).hour().minute()
                : .dateTime.weekday(.wide).day().month(.wide))
        }
        guard await confirm(tr("Aggiungere il promemoria?"), detail) else { return Self.declined }
        try await remindersAccess()
        let reminder = EKReminder(eventStore: events)
        reminder.title = title
        guard let target = events.defaultCalendarForNewReminders() else { throw Refusal(message: "There is no reminders list to add to.") }
        reminder.calendar = target
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(due.time ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day],
                                                                         from: due.date)
            if due.time { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try events.save(reminder, commit: true)
        return ToolBox.Result(text: "Added the reminder \"\(title)\" to \(target.title).", ok: true)
    }

    // MARK: Contacts

    private func contactsSearch(_ arguments: JSON) async throws -> ToolBox.Result {
        let query = try Self.required(arguments, "query")
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: break
        default:
            guard (try? await CNContactStore().requestAccess(for: .contacts)) == true else { throw Self.denied("contacts") }
        }
        // fetching blocks: off the main thread, as Contacts asks
        let lines = try await Task.detached { try Self.contacts(matching: query) }.value
        return ToolBox.Result(text: lines.isEmpty ? "No contact matches \"\(query)\"." : lines.joined(separator: "\n"), ok: true)
    }

    nonisolated private static func contacts(matching query: String) throws -> [String] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactOrganizationNameKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor]
        let digits = query.filter(\.isNumber)
        let byPhone = digits.count >= 5 && digits.count * 2 >= query.filter { !$0.isWhitespace }.count
        let predicate = byPhone ? CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))
            : CNContact.predicateForContacts(matchingName: query)
        return try store.unifiedContacts(matching: predicate, keysToFetch: keys).prefix(10).map { contact in
            var parts = [CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName]
            if !contact.organizationName.isEmpty, parts[0] != contact.organizationName { parts.append(contact.organizationName) }
            for phone in contact.phoneNumbers {
                let label = phone.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) }
                parts.append("phone\(label.map { " (\($0))" } ?? ""): \(phone.value.stringValue)")
            }
            for email in contact.emailAddresses { parts.append("email: \(email.value)") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Alarms

    private func alarmAccess() async throws {
        let manager = AlarmManager.shared
        if manager.authorizationState == .authorized { return }
        guard (try? await manager.requestAuthorization()) == .authorized else { throw Self.denied("alarms") }
    }

    private func schedule(_ schedule: Alarm.Schedule, title: String) async throws {
        try await alarmAccess()
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        } else {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
        }
        let attributes = AlarmAttributes<PhoneAlarmMetadata>(presentation: AlarmPresentation(alert: alert), tintColor: .orange)
        _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: .alarm(schedule: schedule, attributes: attributes))
    }

    private func alarmSet(_ arguments: JSON) async throws -> ToolBox.Result {
        let text = try Self.required(arguments, "time")
        let label = Self.string(arguments, "label")
        let schedule: Alarm.Schedule
        let shown: String
        if let clock = Self.parseClock(text) {
            schedule = .relative(Alarm.Schedule.Relative(time: Alarm.Schedule.Relative.Time(hour: clock.hour, minute: clock.minute)))
            shown = String(format: "%02d:%02d", clock.hour, clock.minute)
        } else if let date = Self.parseDate(text), date.time, date.date > Date() {
            schedule = .fixed(date.date)
            shown = date.date.appFormatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
        } else {
            throw Refusal(message: "\"time\" is not HH:MM or a future YYYY-MM-DDTHH:MM: \(text)")
        }
        guard await confirm(tr("Impostare la sveglia?"), [shown, label].compactMap { $0 }.joined(separator: "\n")) else { return Self.declined }
        try await self.schedule(schedule, title: label ?? tr("Sveglia"))
        return ToolBox.Result(text: "Alarm set for \(text)\(label.map { " (\($0))" } ?? "").", ok: true)
    }

    private func timerSet(_ arguments: JSON) async throws -> ToolBox.Result {
        guard let minutes = Self.integer(arguments, "minutes"), (1...1_440).contains(minutes) else {
            throw Refusal(message: "\"minutes\" must be a whole number from 1 to 1440.")
        }
        let label = Self.string(arguments, "label")
        let fires = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let detail = tr("%@ minuti, suona alle %@", String(minutes), fires.appFormatted(.dateTime.hour().minute()))
        guard await confirm(tr("Avviare il timer?"), [detail, label].compactMap { $0 }.joined(separator: "\n")) else { return Self.declined }
        try await schedule(.fixed(Date().addingTimeInterval(TimeInterval(minutes * 60))), title: label ?? tr("Timer"))
        return ToolBox.Result(text: "Timer started: it rings in \(minutes) minutes\(label.map { " (\($0))" } ?? "").", ok: true)
    }

    // MARK: Dates

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    /// "Fri 2026-10-23 15:42", or without the time.
    static func stamp(_ date: Date, time: Bool) -> String {
        formatter(time ? "EEE yyyy-MM-dd HH:mm" : "EEE yyyy-MM-dd").string(from: date)
    }

    private static func clock(_ date: Date) -> String { formatter("HH:mm").string(from: date) }

    /// A local date, with or without the time. Whatever follows the minutes
    /// or seconds (a zone, "Z") is ignored: models mean the user's own time.
    static func parseDate(_ text: String) -> (date: Date, time: Bool)? {
        let pattern = /^(\d{4}-\d{2}-\d{2})(?:[T ](\d{1,2}):(\d{2}))?/
        guard let match = text.trimmingCharacters(in: .whitespaces).firstMatch(of: pattern),
              let day = formatter("yyyy-MM-dd").date(from: String(match.1)) else { return nil }
        guard let hour = match.2.flatMap({ Int($0) }), let minute = match.3.flatMap({ Int($0) }) else { return (day, false) }
        guard hour < 24, minute < 60, let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return nil }
        return (date, true)
    }

    /// "7:30", "07:30", "19.05".
    static func parseClock(_ text: String) -> (hour: Int, minute: Int)? {
        guard let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(\d{1,2})[:.](\d{2})/),
              let hour = Int(match.1), let minute = Int(match.2), hour < 24, minute < 60 else { return nil }
        return (hour, minute)
    }
}
