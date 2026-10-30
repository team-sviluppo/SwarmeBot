import SwarmeKit
import SwiftUI

/// Stable section ids also used by the settings launch argument.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, engines, remote, connectors, sharing, skills, plugins, vault, phone, mac, keys, deepseek, updates

    var id: String { rawValue }

    static let remoteSections: [Self] = [.general, .engines, .connectors, .skills, .plugins, .vault, .keys, .deepseek]

    static func initial(_ requested: String?, sections: [Self]) -> Self {
        guard let requested, let section = Self(rawValue: requested), sections.contains(section) else { return .general }
        return section
    }

    var title: String {
        switch self {
        case .general: return tr("Generale")
        case .engines: return tr("Motori")
        case .remote: return tr("Server remoti")
        case .connectors: return tr("Connettori")
        case .sharing: return tr("Condivisione")
        case .skills: return tr("Skill")
        case .plugins: return tr("Plugin")
        case .vault: return tr("Vault")
        case .phone: return tr("Telefono")
        case .mac: return tr("Controllo Mac")
        case .keys: return tr("Chiavi e servizi")
        case .deepseek: return tr("DeepSeek")
        case .updates: return tr("Aggiornamenti")
        }
    }

    var icon: String {
        switch self {
        case .general: return "person.crop.circle"
        case .engines: return "cpu"
        case .remote: return "server.rack"
        case .connectors: return "puzzlepiece.extension"
        case .sharing: return "folder.badge.person.crop"
        case .skills: return "wand.and.stars"
        case .plugins: return "shippingbox"
        case .vault: return "lock.shield"
        case .phone: return "iphone"
        case .mac: return "macbook.and.iphone"
        case .keys: return "key"
        case .deepseek: return "network"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// Avoid the native tab toolbar's overflow menu: every section remains selectable.
struct SettingsNavigation<Content: View>: View {
    @Binding var selection: SettingsSection
    let sections: [SettingsSection]
    @ViewBuilder var content: (SettingsSection) -> Content

    var body: some View {
        HStack(spacing: 0) {
            List(sections, selection: Binding<SettingsSection?>(
                get: { selection }, set: { if let section = $0 { selection = section } }
            )) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.icon).foregroundStyle(Theme.secondary)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            .accessibilityLabel(tr("Sezioni delle impostazioni"))
            Divider()
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
