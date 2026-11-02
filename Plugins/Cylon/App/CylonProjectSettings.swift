import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CylonProjectSettingsWire: Decodable {
    var clickupListId: String?
}

extension CompanionClient {
    func cylonProjectSettings(_ project: String) async throws -> CylonProjectSettingsWire {
        try await pluginRequest("GET", "/api/cylon/projects/\(project)", as: CylonProjectSettingsWire.self)
    }

    func saveCylonProjectSettings(_ project: String, listId: String) async throws {
        try await pluginRequest("PUT", "/api/cylon/projects/\(project)", body: ["clickupListId": listId])
    }
}

/// This field is provided only by the enabled Cylon plugin, never by the Code project editor.
struct CylonProjectClickUp: View {
    let project: CylonProject
    @Environment(AppModel.self) private var model
    @State private var listId = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(tr("ID della lista ClickUp"), text: $listId).disabled(loading || saving)
                Button(tr("Salva")) { Task { await save() } }.disabled(loading || saving || listId == original)
                if loading || saving { ProgressView().controlSize(.small) }
            }
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled) }
        }
        .task(id: project.id) {
            do {
                guard let client = model.client else { throw URLError(.notConnectedToInternet) }
                listId = try await client.cylonProjectSettings(project.id).clickupListId ?? ""
                original = listId
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            guard let client = model.client else { throw URLError(.notConnectedToInternet) }
            let value = listId.trimmingCharacters(in: .whitespacesAndNewlines)
            try await client.saveCylonProjectSettings(project.id, listId: value)
            listId = value; original = value
        } catch { self.error = error.localizedDescription }
    }
}
