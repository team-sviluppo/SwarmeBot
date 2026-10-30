import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct ScriptRun: Decodable {
    var id: String
    var name: String
    var command: String
    var folder: String
    var output: String
    var truncated: Bool
    var running: Bool
    var stopped: Bool
    var exitCode: Int?
}

struct ScriptStatus: Decodable {
    var scripts: [ProjectScript]
    var run: ScriptRun?
}

extension CodeState {
    func refreshScripts(model: AppModel, thread: String) async {
        guard let client = model.client else { return }
        do { scriptStatus[thread] = try await client.pluginRequest("GET", "/api/threads/\(thread)/code/scripts", as: ScriptStatus.self) }
        catch {
            if !Task.isCancelled { scriptErrors[thread] = error.localizedDescription }
        }
    }

    func runScript(model: AppModel, thread: String, index: Int) async {
        scriptPanels.insert(thread)
        scriptErrors[thread] = nil
        do {
            try await model.client?.pluginRequest("POST", "/api/threads/\(thread)/code/scripts", body: ["index": index])
            await refreshScripts(model: model, thread: thread)
        } catch { scriptErrors[thread] = error.localizedDescription }
    }
}

struct CodeScriptButton: View {
    let state: CodeState
    let thread: String
    @Environment(AppModel.self) private var model
    var body: some View {
        Menu {
            ForEach(Array((state.scriptStatus[thread]?.scripts ?? []).enumerated()), id: \.offset) { index, script in
                Button(script.name) { Task { await state.runScript(model: model, thread: thread, index: index) } }
                    .disabled(state.scriptStatus[thread]?.run?.running == true)
            }
            if state.scriptStatus[thread]?.scripts.isEmpty != false {
                Text(tr("Configura gli script nelle impostazioni del progetto"))
            }
            Divider()
            Button(tr("Mostra output")) { state.scriptPanels.insert(thread) }
        } label: { Label(tr("Script"), systemImage: "play.rectangle").fixedSize() }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
        .fixedSize()
        .task(id: thread) { await state.refreshScripts(model: model, thread: thread) }
    }
}

struct CodeScriptPanel: View {
    let state: CodeState
    let thread: String
    @Environment(AppModel.self) private var model
    private var run: ScriptRun? { state.scriptStatus[thread]?.run }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(run?.name ?? tr("Script")).font(.system(size: 12, weight: .semibold))
                if let run {
                    if run.running { ProgressView().controlSize(.mini) }
                    else { Text(run.stopped ? tr("Interrotto") : tr("Uscita %@", String(run.exitCode ?? -1)))
                        .foregroundStyle(run.exitCode == 0 ? Theme.success : Theme.danger).font(.system(size: 11.5)) }
                }
                Spacer()
                if run?.running == true {
                    Button(tr("Stop")) {
                        Task {
                            do { try await model.client?.pluginRequest("POST", "/api/threads/\(thread)/code/scripts/stop", body: [:]) }
                            catch { state.scriptErrors[thread] = error.localizedDescription }
                        }
                    }
                } else if let run, run.exitCode != 0, !run.stopped {
                    Button(tr("Manda l'errore al bot")) {
                        let tail = run.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(60).joined(separator: "\n")
                        Task { await model.send("The project script \(run.name) failed in \(run.folder).\nCommand: \(run.command)\nExit: \(run.exitCode ?? -1)\n\n\(tail)\n\nPlease investigate and fix the failure.") }
                    }
                }
                Button { state.scriptPanels.remove(thread) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if let error = state.scriptErrors[thread] { Text(verbatim: error).foregroundStyle(Theme.danger).font(.caption) }
            if run?.truncated == true { Text(tr("Output abbreviato: sono visibili le ultime righe")).font(.caption).foregroundStyle(Theme.tertiary) }
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: run?.output.isEmpty == false ? run!.output : tr("Nessun output"))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 130)
        }
        .padding(12).background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .task(id: thread) {
            while !Task.isCancelled {
                let wasRunning = run?.running == true
                await state.refreshScripts(model: model, thread: thread)
                if wasRunning && run?.running == false { await state.refreshGit(model: model, threadId: thread) }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            }
        }
    }
}
