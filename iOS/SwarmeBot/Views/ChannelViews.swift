// Channels, as on the Mac: several bots in one conversation. A channel on a
// server (the engine's rooms) has that server's bots, sharing its folder; a
// channel on the phone (LocalRooms.swift) has the phone's bots and, as
// guests, bots of any paired server (a mixed channel): each answers from
// where it lives.
import CompanionCore
import PhotosUI
import SwiftUI

/// A channel of the phone's bots.
struct LocalRoomRoute: Hashable {
    let roomId: String
}

/// Where a new channel goes: the phone, or a paired server.
private enum ChannelPlace: Hashable {
    case phone
    case server(String)
}

struct NewChannelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The channel made, to open.
    let created: (AnyHashable) -> Void

    @State private var name = ""
    @State private var place: ChannelPlace = .phone
    @State private var members: [String] = []
    @State private var guests: [String] = []
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Nome (facoltativo)"), text: $name)
                if !model.sessions.isEmpty {
                    Picker(tr("Dove"), selection: $place) {
                        Text(tr("Sul telefono")).tag(ChannelPlace.phone)
                        ForEach(model.sessions) { session in
                            Text(verbatim: session.server.name).tag(ChannelPlace.server(session.id))
                        }
                    }
                }
                switch place {
                case .phone:
                    PhoneChannelMembers(members: $members, guests: $guests, footer: footer)
                case let .server(id):
                    Section {
                        ForEach(model.session(id)?.visibleBots ?? []) { bot in
                            memberToggle(bot.id) {
                                RemoteBotAvatar(bot: bot, size: 30, animated: false)
                                Text(verbatim: bot.name)
                            }
                        }
                    } header: {
                        Text(tr("Membri"))
                    } footer: {
                        Text(footer)
                    }
                }
            }
            .navigationTitle(tr("Nuovo canale"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Crea")) { Task { await create() } }.disabled(members.isEmpty && guests.isEmpty || creating)
                }
            }
            .onChange(of: place) { _, _ in
                members = []
                guests = []
            }
        }
    }

    private var footer: String {
        switch place {
        case .phone:
            return tr("I bot rispondono uno alla volta, ognuno col suo modello; per chiamarne uno scrivi @Nome. Il canale resta su questo telefono; i bot dei server rispondono da lì, nelle loro cartelle.")
        case .server:
            return tr("I bot rispondono uno alla volta, per chiamarne uno scrivi @Nome. Sul server lavorano nella stessa cartella del canale.")
        }
    }

    private func memberToggle<Label: View>(_ id: String, @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { members.contains(id) }, set: { on in
            if on { members.append(id) } else { members.removeAll { $0 == id } }
        })) {
            HStack(spacing: 10) { label() }
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        switch place {
        case .phone:
            let room = model.local.addRoom(name: name, memberIds: members, guests: model.roomGuests(guests))
            dismiss()
            created(LocalRoomRoute(roomId: room.id))
        case let .server(id):
            guard let session = model.session(id), let room = await session.createRoom(name: name, memberIds: members) else { return }
            dismiss()
            created(Route(serverId: id, chat: .room(room.id)))
        }
    }
}

/// The members of a channel on the phone: its bots, then each paired
/// server's bots as guests.
private struct PhoneChannelMembers: View {
    @Environment(AppModel.self) private var model
    @Binding var members: [String]
    /// `RoomGuest.memberId`s.
    @Binding var guests: [String]
    var footer: String? = nil

    var body: some View {
        Section {
            ForEach(model.local.bots) { bot in
                toggle(bot.id, in: $members) {
                    LocalBotAvatar(bot: bot, size: 30)
                    Text(verbatim: bot.name)
                }
            }
        } header: {
            Text(tr("Sul telefono"))
        } footer: {
            if let footer { Text(footer) }
        }
        ForEach(model.sessions) { session in
            if !session.visibleBots.isEmpty {
                Section(tr("Ospiti da %@", session.server.name)) {
                    ForEach(session.visibleBots) { bot in
                        toggle(RoomGuest(peerId: session.id, botId: bot.id, name: bot.name, color: bot.color).memberId, in: $guests) {
                            RemoteBotAvatar(bot: bot, size: 30, animated: false)
                            Text(verbatim: bot.name)
                        }
                    }
                }
            }
        }
    }

    private func toggle<Label: View>(_ id: String, in list: Binding<[String]>, @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { list.wrappedValue.contains(id) }, set: { on in
            if on { list.wrappedValue.append(id) } else { list.wrappedValue.removeAll { $0 == id } }
        })) {
            HStack(spacing: 10) { label() }
        }
    }
}

/// Who answers a message without @mentions: everyone, only who is
/// mentioned, or one member (the first, unless chosen).
struct ResponderMenu: View {
    let kind: String
    let botId: String?
    let members: [(id: String, name: String)]
    let set: (String, String?) -> Void

    var body: some View {
        Menu {
            Picker(tr("Chi risponde"), selection: Binding(get: { selection }, set: choose)) {
                Text(tr("Tutti")).tag("everyone")
                Text(tr("Solo chi è menzionato")).tag("mentions")
                ForEach(members, id: \.id) { member in
                    Text(verbatim: member.name).tag("member:" + member.id)
                }
            }
        } label: {
            Label(tr("Chi risponde"), systemImage: "person.wave.2")
        }
    }

    private var selection: String {
        switch kind {
        case "everyone", "mentions": return kind
        default: return "member:" + (botId.flatMap { id in members.contains { $0.id == id } ? id : nil } ?? members.first?.id ?? "")
        }
    }

    private func choose(_ tag: String) {
        if tag.hasPrefix("member:") { set("member", String(tag.dropFirst(7))) } else { set(tag, nil) }
    }
}

/// A channel's avatar: the first members' mascots, overlapping.
struct LocalRoomAvatar: View {
    let members: [RoomMember]
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            if let first = members.first {
                mascot(first).offset(x: -size * 0.15, y: -size * 0.12)
            }
            if members.count > 1 {
                mascot(members[1]).offset(x: size * 0.15, y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func mascot(_ member: RoomMember) -> some View {
        switch member {
        case let .phone(bot): LocalBotAvatar(bot: bot, size: size * 0.7, animated: false)
        case .guest: SwarmeAvatar(color: member.color, size: size * 0.7, state: .idle, animated: false, trackPointer: false)
        }
    }
}

/// A channel of the phone's bots: who said what, the reply streaming under
/// the name of who is speaking, the composer (text only).
struct LocalRoomView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let roomId: String

    @State private var draft = ""
    @State private var photo: PhotosPickerItem?
    @State private var deleting = false
    @State private var editing = false

    private var room: LocalRoom? { model.local.room(roomId) }
    private var chat: LocalRoomChat { model.local.roomChat(roomId) }
    private var members: [RoomMember] { room.map(model.local.members) ?? [] }
    private var screenKey: String { Notifier.key(phoneRoom: roomId) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if chat.messages.isEmpty, !chat.busy {
                    VStack(spacing: 12) {
                        LocalRoomAvatar(members: members, size: 96)
                        Text(tr("Scrivi @Nome per chiamare un bot, @everyone per tutti. Il canale resta su questo telefono."))
                            .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.horizontal, 24)
                }
                ForEach(chat.messages) { message in
                    row(message).id(message.id)
                }
                if chat.busy, let speaker = chat.speaker.flatMap(chat.member) {
                    if chat.streaming.isEmpty {
                        ActivityLine(text: tr("%@ sta pensando…", speaker.name), running: true).id("live")
                    } else {
                        ChatBubble(text: chat.streaming, isUser: false, color: speaker.color, header: speaker.name,
                                   headerColor: speaker.color).id("live")
                    }
                }
                if let error = chat.lastError {
                    ActivityLine(text: error, failed: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .stickToBottom(last: chat.messages.last?.id)
        .safeAreaInset(edge: .bottom) {
            ComposerBar(text: $draft, placeholder: tr("Scrivi nel canale"), takesImages: false, photo: $photo, busy: chat.busy,
                        send: {
                            chat.send(draft)
                            draft = ""
                        },
                        stop: { chat.stop() })
        }
        .background(Theme.app)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitlePill(title: room?.name ?? tr("Canale"), action: { editing = true }) {
                    LocalRoomAvatar(members: members, size: 30)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let room {
                        ResponderMenu(kind: room.responder ?? "member", botId: room.responderBotId,
                                      members: members.map { ($0.id, $0.name) }) { kind, botId in
                            var changed = room
                            changed.responder = kind
                            changed.responderBotId = botId
                            model.local.save(changed)
                        }
                    }
                    Button(tr("Modifica il canale"), systemImage: "slider.horizontal.3") { editing = true }
                    if chat.busy {
                        Button(tr("Ferma"), systemImage: "stop.circle") { chat.stop() }
                    }
                    Divider()
                    Button(tr("Elimina il canale"), systemImage: "trash", role: .destructive) { deleting = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .confirmationDialog(tr("Eliminare %@?", room?.name ?? ""), isPresented: $deleting, titleVisibility: .visible) {
            Button(tr("Elimina"), role: .destructive) {
                if let room { model.local.delete(room) }
            }
        } message: {
            Text(tr("La conversazione è solo su questo telefono: si perde anche quella. I bot restano."))
        }
        .sheet(isPresented: $editing) {
            if let room { LocalRoomEditor(room: room) }
        }
        // deleted here, or its last member was: back to the list
        .onChange(of: room == nil) { _, gone in if gone { dismiss() } }
        .onAppear {
            Notifier.shared.onScreen = screenKey
            model.local.markRead(room: roomId)
        }
        .onDisappear { if Notifier.shared.onScreen == screenKey { Notifier.shared.onScreen = nil } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.local.markRead(room: roomId) } }
    }

    @ViewBuilder
    private func row(_ message: LocalMessage) -> some View {
        let speaker = message.from.flatMap(chat.member)
        switch message.role {
        case .user:
            ChatBubble(text: message.text, isUser: true, color: "blue")
        case .bot:
            ChatBubble(text: message.text, isUser: false, color: speaker?.color ?? "blue", header: speaker?.name ?? tr("Bot eliminato"),
                       headerColor: speaker?.color, footnote: message.interrupted ? tr("Interrotto") : nil)
        case .tool:
            if let tool = message.tool {
                ActivityLine(text: [speaker?.name, tool.name].compactMap { $0 }.joined(separator: " · "), failed: tool.ok == false,
                             running: tool.ok == nil)
            }
        case .note:
            ActivityLine(text: message.text, symbol: "info.circle")
        }
    }
}

/// A phone channel's name and members.
private struct LocalRoomEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let room: LocalRoom
    @State private var name = ""
    @State private var members: [String] = []
    @State private var guests: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                TextField(tr("Nome"), text: $name)
                PhoneChannelMembers(members: $members, guests: $guests)
            }
            .navigationTitle(tr("Modifica il canale"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Salva")) {
                        var changed = room
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { changed.name = trimmed }
                        changed.memberIds = members
                        // guests kept keep their names, even with their server offline
                        let kept = (room.guests ?? []).filter { guests.contains($0.memberId) }
                        let added = model.roomGuests(guests.filter { id in !kept.contains { $0.memberId == id } })
                        changed.guests = kept + added
                        if changed.guests?.isEmpty == true { changed.guests = nil }
                        model.local.save(changed)
                        dismiss()
                    }
                    .disabled(members.isEmpty && guests.isEmpty)
                }
            }
            .onAppear {
                name = room.name
                members = room.memberIds
                guests = (room.guests ?? []).map(\.memberId)
            }
        }
    }
}
