// Impostazioni: the app's language and the paired servers.
import SwiftUI
import UserNotifications

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
                NotificationsSection()
                Section(tr("Sul telefono")) {
                    NavigationLink(tr("Server compatibili OpenAI")) { ServersView() }
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

/// Whether the phone may tell: ask, or send to the system's settings once refused.
private struct NotificationsSection: View {
    @State private var status: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            switch status {
            case .notDetermined:
                Button(tr("Attiva le notifiche")) {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        await refresh()
                    }
                }
            case .denied:
                Button(tr("Apri le impostazioni di iOS")) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            case .some:
                Label(tr("Notifiche attive"), systemImage: "checkmark")
            case nil:
                EmptyView()
            }
        } header: {
            Text(tr("Notifiche"))
        } footer: {
            Text(tr("Il telefono avvisa quando un bot finisce o chiede un permesso, e l'icona dell'app conta le chat non lette. Con l'app chiusa, i bot dei server si controllano quando iOS lo concede: l'avviso può arrivare in ritardo."))
        }
        .task(id: scenePhase) { await refresh() }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
