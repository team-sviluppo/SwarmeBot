import Foundation

public struct SharedSource: Codable, Hashable, Sendable {
    public var folder: String
    public var id: String
}

public enum SharedRepositoryKind: String, CaseIterable, Sendable {
    case bots, connectors
}

public struct SharedRepository: Decodable, Sendable {
    public var folder: String?
    public var fileName: String
    public var entries: [SharedRepositoryEntry]
    public var problem: String?
}

public struct SharedRepositoryEntry: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var imported: Bool
    public var conflict: Bool
}

extension CompanionClient {
    public func sharedRepository(_ kind: SharedRepositoryKind) async throws -> SharedRepository {
        try await send(try makeRequest("GET", "/api/shared-repositories/\(kind.rawValue)"), as: SharedRepository.self)
    }

    public func setSharedFolder(_ kind: SharedRepositoryKind, _ path: String?) async throws -> SharedRepository {
        try await send(try makeRequest("PUT", "/api/shared-repositories/\(kind.rawValue)", body: ["folder": path as Any? ?? NSNull()]), as: SharedRepository.self)
    }

    public func importShared(_ kind: SharedRepositoryKind, ids: [String]) async throws -> SharedRepository {
        try await send(try makeRequest("POST", "/api/shared-repositories/\(kind.rawValue)/import", body: ["ids": ids]), as: SharedRepository.self)
    }

    public func publishShared(_ kind: SharedRepositoryKind, id: String) async throws -> SharedRepository {
        try await send(try makeRequest("POST", "/api/shared-repositories/\(kind.rawValue)/publish", body: ["id": id]), as: SharedRepository.self)
    }

    public func syncSharedRepositories() async throws -> [String] {
        struct Answer: Decodable { var problems: [String] }
        return try await send(try makeRequest("POST", "/api/shared-repositories/sync", body: [:]), as: Answer.self).problems
    }
}
