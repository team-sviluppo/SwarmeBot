// Pairing with a remote engine (plan §5.1): the Mac shows a QR with
// `swarmebot://pair?url=…&code=…&name=…`; this reads it with the camera, or
// takes the link pasted, and trades the one-time code for a token.
import CompanionCore
import SwiftUI
import VisionKit

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialLink: RemotePairingLink?

    @State private var pasted = ""
    @State private var working = false
    @State private var error: String?

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Form {
                if let initialLink {
                    Section {
                        LabeledContent(tr("Server"), value: initialLink.name ?? initialLink.chatURL)
                        Button(tr("Abbina questo telefono")) { Task { await pair(initialLink) } }
                            .disabled(working)
                    }
                } else if scannerAvailable {
                    Section {
                        QRScanner { text in
                            guard !working, let url = URL(string: text) else { return }
                            if let link = RemotePairingLink(url: url) {
                                Task { await pair(link) }
                            } else if let link = PhoneConfigLink(url: url) {
                                // the Mac's other QR: settings for the phone's own bots
                                model.pendingImport = .link(link)
                                dismiss()
                            }
                        }
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets())
                    } footer: {
                        Text(tr("Inquadra il QR che il Mac mostra in Impostazioni › server › Abbina telefono."))
                    }
                }
                Section {
                    TextField("", text: $pasted, prompt: Text(verbatim: "swarmebot://pair?…"), axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button(tr("Abbina")) {
                        guard let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)),
                              let link = RemotePairingLink(url: url) else {
                            error = tr("Questo non è un link di abbinamento di SwarmeBot.")
                            return
                        }
                        Task { await pair(link) }
                    }
                    .disabled(working || pasted.isEmpty)
                } header: {
                    Text(tr("Oppure incolla il link"))
                }
                if working {
                    Section { ProgressView(tr("Abbinamento…")) }
                }
                if let error {
                    Section { Text(verbatim: error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(tr("Abbina un server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
            }
        }
    }

    private func pair(_ link: RemotePairingLink) async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.pair(link)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The camera, reading QR codes; hands on every payload it recognizes.
private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case let .barcode(code) = item, let payload = code.payloadStringValue { found(payload) }
            }
        }
    }
}
