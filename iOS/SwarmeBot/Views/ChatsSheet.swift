// A bot's chats, as the desktop's task picker: the older ones to reopen,
// a new one, a swipe to delete. The same sheet for remote and phone bots.
import SwiftUI

struct ChatsSheet: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let date: Date
        let current: Bool
    }

    let botName: String
    let items: [Item]
    let onNew: () -> Void
    let onOpen: (String) -> Void
    let onDelete: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onNew()
                        dismiss()
                    } label: {
                        Label(tr("Nuova chat"), systemImage: "square.and.pencil").foregroundStyle(Theme.ink)
                    }
                }
                Section {
                    ForEach(items) { item in
                        Button {
                            onOpen(item.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: item.title.isEmpty ? tr("Chat senza titolo") : item.title)
                                        .foregroundStyle(Theme.ink).lineLimit(1)
                                    Text(verbatim: item.date.listStamp()).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                if item.current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                        .swipeActions {
                            if items.count > 1 {
                                Button(tr("Elimina"), role: .destructive) { onDelete(item.id) }
                            }
                        }
                    }
                } header: {
                    Text(tr("Chat precedenti"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.app)
            .navigationTitle(botName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Fine")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
