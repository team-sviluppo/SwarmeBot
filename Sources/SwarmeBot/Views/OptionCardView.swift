import CompanionCore
import SwarmeKit
import SwiftUI

/// An approval or a question, inline in the transcript.
///
/// Approvals (`ApprovalCard.tsx`) show what the bot wants to run and their
/// status; the live one is answered from the composer's pending panel (⏎
/// allows once, ⎋ denies). Questions (`OptionCard.tsx`) are answered here:
/// a bordered list of options with letter badges and a free-text field.
struct OptionCardView: View {
    let card: OptionCard
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var sending = false
    @State private var custom = ""
    @State private var picked: Set<String> = []
    @State private var hovered: String?

    var body: some View {
        Group {
            if card.isPermission { approval } else { question }
        }
        .padding(16)
        .frame(maxWidth: 840, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .opacity(card.isPermission && !card.isPending ? 0.7 : 1)
        .disabled(sending)
    }

    private var border: Color {
        if card.isPermission { return card.isPending ? Theme.accent.opacity(0.4) : Theme.hairline.opacity(0.3) }
        return Theme.hairline.opacity(0.5)
    }

    // MARK: Approval

    private var approval: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                if let tool = card.tool {
                    Text(tool).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                }
            }
            if !card.subtitle.isEmpty {
                ScrollView {
                    Text(card.subtitle)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.inset))
                .padding(.top, 8)
            }
            if let held = card.held, !held.isEmpty {
                Text(held)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.warning.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.warning.opacity(0.3)))
                    .padding(.top, 8)
            }
            HStack(spacing: 6) {
                Image(systemName: status.icon).font(.system(size: 13)).foregroundStyle(status.tint)
                Text(status.text).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 12)
        }
    }

    private var status: (icon: String, tint: Color, text: String) {
        if card.isPending { return ("checkmark.shield", Theme.accent, "In attesa della tua risposta qui sotto") }
        switch card.answered?.lowercased() {
        case "allow"?: return ("checkmark", Theme.success, "Consentito")
        case "deny"?: return ("xmark", Theme.secondary, "Negato")
        case let other?: return ("checkmark", Theme.success, other)
        case nil: return ("exclamationmark.triangle", Theme.warning,
                          card.dismissed == true ? "Ignorata" : "Non disponibile · azione non eseguita")
        }
    }

    // MARK: Question

    private var question: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                if !card.subtitle.isEmpty {
                    Text(card.subtitle).font(.system(size: 14)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }
            if card.isPending {
                VStack(spacing: 0) {
                    ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            if card.multiSelect == true {
                                if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
                            } else {
                                answer(option)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(UnicodeScalar(UInt8(65 + index % 26))))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                                Text(option).font(.system(size: 15)).foregroundStyle(Theme.ink)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if card.multiSelect == true, picked.contains(option) {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(12)
                            .background(picked.contains(option) ? Theme.raised : hovered == option ? Theme.raised.opacity(0.6) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside { hovered = option } else if hovered == option { hovered = nil }
                        }
                        if index < card.options.count - 1 {
                            Rectangle().fill(Theme.hairline.opacity(0.4)).frame(height: 1)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).stroke(Theme.hairline.opacity(0.4)))
                .padding(.top, 12)
                HStack(spacing: 8) {
                    TextField("", text: $custom, prompt: Text("Scrivi la tua risposta").foregroundStyle(Theme.secondary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.inset))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow).stroke(Theme.hairline.opacity(0.4)))
                        .onSubmit(submitCustom)
                    if card.multiSelect == true || !custom.isEmpty {
                        Button("Invia", action: submitCustom)
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.accent))
                            .disabled(card.multiSelect == true ? picked.isEmpty && custom.isEmpty : custom.isEmpty)
                    }
                }
                .padding(.top, 12)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: card.answered == nil ? "minus.circle" : "checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(card.answered == nil ? Theme.secondary : Theme.success)
                    Text(card.dismissed == true ? "Ignorata" : card.answered ?? "Scaduta")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.top, 12)
            }
        }
    }

    private func submitCustom() {
        if card.multiSelect == true {
            sending = true
            let ordered = card.options.filter(picked.contains)
            Task {
                await model.answer(threadId: threadId, card: card, selected: ordered, custom: custom.isEmpty ? nil : custom)
                sending = false
            }
        } else if !custom.isEmpty {
            answer(custom)
        }
    }

    private func answer(_ choice: String) {
        sending = true
        Task {
            await model.answer(threadId: threadId, card: card, choice: choice)
            sending = false
        }
    }
}
