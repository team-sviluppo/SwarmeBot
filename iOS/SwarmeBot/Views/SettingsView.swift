// Impostazioni: the app's language and the paired servers.
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var localizer = Localizer.shared
    @State private var removing: RemoteSession?

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Generale")) {
                    Picker(tr("Lingua"), selection: $localizer.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.nativeName).tag(language)
                        }
                    }
                }
                Section(tr("Sul telefono")) {
                    NavigationLink(tr("Connettori")) { ConnectorsView() }
                    NavigationLink(tr("Modelli sul telefono")) { ModelsView() }
                }
                Section {
                    ForEach(model.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: session.server.name)
                            Text(verbatim: session.server.chatURL).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(tr("Rimuovi"), role: .destructive) { removing = session }
                        }
                    }
                } header: {
                    Text(tr("Server"))
                } footer: {
                    Text(tr("Rimuovere un server lo dimentica su questo telefono. Per revocarne l'accesso, usa la scheda del server sul Mac."))
                }
            }
            .navigationTitle(tr("Impostazioni"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("Fine")) { dismiss() } }
            }
            .confirmationDialog(tr("Rimuovere %@?", removing?.server.name ?? ""), isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible) {
                Button(tr("Rimuovi"), role: .destructive) {
                    if let removing { model.remove(removing) }
                    removing = nil
                }
            }
        }
    }
}
