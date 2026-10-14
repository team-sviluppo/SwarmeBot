import CompanionCore
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

/// Ready-made teams from the public catalog or a GitHub URL, import from a
/// file, and export of the current fleet.
struct TeamLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var catalog: [TeamCatalogEntry] = []
    @State private var loading = true
    @State private var catalogError: String?
    @State private var githubURL = ""
    @State private var replace = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Libreria team").font(.system(size: 18, weight: .semibold))
                Spacer()
                Toggle("Sostituisci i bot attuali", isOn: $replace).toggleStyle(.checkbox)
                Button("Importa file…", action: importFile)
                Button("Esporta team…", action: exportTeam)
            }
            .padding(16)
            HStack {
                TextField("URL GitHub di un team", text: $githubURL).textFieldStyle(.roundedBorder)
                Button("Carica") { Task { await importGitHub() } }.disabled(githubURL.isEmpty)
            }
            .padding(.horizontal, 16)
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 6)
            }
            Divider().padding(.top, 12)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalogError != nil || catalog.isEmpty {
                // The catalog route exists on the harness but no client has
                // relied on it; GitHub and file import are the real paths.
                ContentUnavailableView(
                    "Catalogo non disponibile",
                    systemImage: "books.vertical",
                    description: Text("Importa un team da un URL GitHub o da un file JSON esportato.")
                )
            } else {
                List(catalog) { team in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(team.name).font(.system(size: 13.5, weight: .semibold))
                            if let summary = team.summary { Text(summary).font(.system(size: 12)).foregroundStyle(.secondary) }
                            let members = (team.members ?? []).compactMap(\.name)
                            if !members.isEmpty {
                                Text(members.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Button("Importa") { Task { await importCatalog(team) } }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 460, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .task {
            guard let client = model.client else { return }
            do {
                catalog = try await client.teamCatalog().teams
            } catch {
                catalogError = error.localizedDescription
            }
            loading = false
        }
    }

    private var mode: String { replace ? "replace" : "add" }

    private func importCatalog(_ team: TeamCatalogEntry) async {
        guard let manifest = try? await model.client?.teamManifest(slug: team.slug),
              let data = try? JSONEncoder().encode(manifest) else {
            status = "Impossibile scaricare \(team.name)."
            return
        }
        status = await model.importTeam(data, mode: mode) ? "Importato \(team.name)." : nil
    }

    private func importGitHub() async {
        do {
            guard let manifest = try await model.client?.teamManifest(github: githubURL) else { return }
            let data = try JSONEncoder().encode(manifest)
            status = await model.importTeam(data, mode: mode) ? "Team importato da GitHub." : nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task { status = await model.importTeam(data, mode: mode) ? "Importato \(url.lastPathComponent)." : nil }
    }

    private func exportTeam() {
        Task {
            guard let data = await model.exportTeam(name: nil) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "swarmebot-team.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                status = "Esportato in \(url.lastPathComponent)."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
