// Provider instances by id — `server/harness/registry.ts`.
//
// An instance whose driver this engine does not have (yet), or whose
// create() failed, is kept as a *shadow*: listed, unavailable, with the
// reason. That is how a config written by the Node engine — or by a newer
// build — downgrades safely here instead of disappearing.
import Foundation

public struct InstanceConfig: Sendable {
    public var driver: String
    public var displayName: String?
    public var environment: [String: String]
    public var enabled: Bool
    public var config: JSON
}

@MainActor
public final class Registry {
    private struct Shadow {
        var driverKind: String
        var displayName: String?
        var reason: String
        var cli: String?
    }

    private var live: [InstanceID: ProviderInstance] = [:]
    private var shadows: [InstanceID: Shadow] = [:]
    private var order: [InstanceID] = []
    private var cliByInstance: [InstanceID: String] = [:]
    private var described: [JSON] = []
    private let drivers: [String: ProviderDriver]

    /// Driver kinds the Node engine has and this one does not yet.
    public static let notYetPortedReason = "non ancora disponibile nel motore Swift — usa il motore Node in Impostazioni › Motore"

    public init(drivers: [ProviderDriver]) {
        var map: [String: ProviderDriver] = [:]
        for driver in drivers { map[driver.driverKind] = driver }
        self.drivers = map
    }

    public func load(_ configs: [(InstanceID, InstanceConfig)], baseEnvironment: [String: String]) async {
        for (instanceId, entry) in configs {
            order.append(instanceId)
            if let cli = entry.config["cli"]?.string, !cli.isEmpty { cliByInstance[instanceId] = cli }
            guard let driver = drivers[entry.driver] else {
                shadows[instanceId] = Shadow(driverKind: entry.driver, displayName: entry.displayName,
                                             reason: Self.notYetPortedReason, cli: entry.config["cli"]?.string)
                continue
            }
            let environment = baseEnvironment.merging(entry.environment) { _, new in new }
            do {
                let instance = try await driver.create(DriverCreateInput(
                    instanceId: instanceId, displayName: entry.displayName,
                    environment: environment, enabled: entry.enabled, config: entry.config
                ))
                live[instanceId] = instance
            } catch {
                shadows[instanceId] = Shadow(driverKind: entry.driver, displayName: entry.displayName,
                                             reason: error.localizedDescription, cli: entry.config["cli"]?.string)
            }
        }
    }

    public func get(_ id: InstanceID) -> ProviderInstance? { live[id] }

    public func instances() -> [ProviderInstance] { order.compactMap { live[$0] } }

    public func driver(_ kind: String) -> ProviderDriver? { drivers[kind] }

    /// `GET /api/instances` rows, in config order.
    ///
    /// `refresh` probes CLIs and remote catalogs. A picker-visibility change
    /// skips that: the last row is reused and only the flag is rewritten.
    public func describe(pickerVisibility: [String: Bool], refresh: Bool = true) async -> [JSON] {
        if !refresh, !described.isEmpty {
            let rows = described.map { row -> JSON in
                guard var object = row.object, let id = object["instanceId"]?.string else { return row }
                if let visible = pickerVisibility[id] { object["pickerVisible"] = .bool(visible) }
                else { object["pickerVisible"] = nil }
                return .object(object)
            }
            described = rows
            return rows
        }
        var rows: [JSON] = []
        for id in order {
            var row = JSONObject()
            if let shadow = shadows[id] {
                let driver = drivers[shadow.driverKind]
                row["instanceId"] = .string(id)
                row["driverKind"] = .string(shadow.driverKind)
                row["displayName"] = .string(shadow.displayName ?? shadow.driverKind)
                row["snapshot"] = ProviderSnapshot.unavailable(shadow.reason).json
                row["models"] = ModelCatalog.empty.json
                row["capabilities"] = ["computerMcp": false, "agentsMcp": false, "localComputerMcp": false]
                row["access"] = .string(driver?.access ?? "subscription")
                if let install = driver?.install { row["install"] = install.json }
                if let cli = shadow.cli { row["cli"] = .string(cli) }
                if let cliDefault = driver?.cliDefault { row["cliDefault"] = .string(cliDefault) }
                row["cliCandidates"] = .array([])
            } else if let instance = live[id] {
                await instance.refreshModels()
                let driver = drivers[instance.driverKind]
                row["instanceId"] = .string(id)
                row["driverKind"] = .string(instance.driverKind)
                row["displayName"] = .string(instance.displayName ?? instance.driverKind)
                row["snapshot"] = await instance.snapshot().json
                row["models"] = instance.models.json
                row["capabilities"] = instance.adapter.capabilities.json
                row["access"] = .string(driver?.access ?? "subscription")
                if let install = driver?.install { row["install"] = install.json }
                if let cli = cliByInstance[id] { row["cli"] = .string(cli) }
                if let cliDefault = driver?.cliDefault { row["cliDefault"] = .string(cliDefault) }
                row["cliCandidates"] = .strings(driver?.cliDefault.map { EnvPath.candidates($0) } ?? [])
            } else {
                continue
            }
            if let visible = pickerVisibility[id] { row["pickerVisible"] = .bool(visible) }
            rows.append(.object(row))
        }
        described = rows
        return rows
    }

    /// The default selection for new bots: first available, Claude preferred.
    public func defaultSelection() async -> ModelSelection {
        var available: [ProviderInstance] = []
        for instance in instances() where await instance.snapshot().state == "available" {
            available.append(instance)
        }
        let pick = available.first { $0.driverKind == "claudeAgent" } ?? available.first
        return ModelSelection(instanceId: pick?.instanceId ?? "", model: pick?.models.default ?? "")
    }

    public func stopAll() async {
        for instance in instances() { await instance.adapter.stopAll() }
    }
}
