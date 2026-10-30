import CompanionCore
import SwarmeKit
import SwiftUI

/// The same answer controls for provider requests and choices in a final reply.
struct QuestionChoicesView: View {
    let options: [String]
    var multiSelect = false
    let submit: ([String], String?) async -> Void
    @State private var picked: Set<Int> = []
    @State private var other = false
    @State private var custom = ""
    @State private var sending = false
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button {
                        if multiSelect {
                            if picked.contains(index) { picked.remove(index) } else { picked.insert(index) }
                        } else { send([option], nil) }
                    } label: {
                        row(option, badge: String(index + 1), selected: picked.contains(index))
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                Button {
                    other.toggle()
                    writing = other
                } label: {
                    row(tr("Altro"), badge: "…", selected: other)
                }.buttonStyle(.plain)
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.hairline.opacity(0.4)))
            if other || options.isEmpty {
                TextField(tr("Scrivi la tua risposta"), text: $custom)
                    .textFieldStyle(.roundedBorder).focused($writing).onSubmit(answer)
            }
            if multiSelect || other || options.isEmpty {
                Button(tr("Invia"), action: answer)
                    .buttonStyle(ChipButtonStyle(filled: true, size: 13))
                    .disabled(picked.isEmpty && answerText.isEmpty)
            }
        }
        .disabled(sending)
    }

    private var answerText: String {
        (other || options.isEmpty ? custom : "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func row(_ title: String, badge: String, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: badge).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
            Text(verbatim: title).font(.system(size: 14)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
        }.padding(12).contentShape(Rectangle())
            .background(selected ? Theme.raised : .clear)
    }

    private func answer() {
        let selected = options.enumerated().filter { picked.contains($0.offset) }.map(\.element)
        guard !selected.isEmpty || !answerText.isEmpty else { return }
        send(selected, answerText.isEmpty ? nil : answerText)
    }

    private func send(_ selected: [String], _ custom: String?) {
        sending = true
        Task {
            await submit(selected, custom)
            sending = false
        }
    }
}
