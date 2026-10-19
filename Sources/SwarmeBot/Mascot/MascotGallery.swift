// Debug aid: every silhouette, colour and a spread of states on one screen.
// `SWARMEBOT_MASCOT_GALLERY=1` shows it in place of the chat window, for
// snapshots (see SWARMEBOT_SNAPSHOT).
import SwiftUI

struct MascotGallery: View {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SWARMEBOT_MASCOT_GALLERY"] == "1" }

    private let states: [SwarmeState] = [.idle, .happy, .curious, .working, .thinking, .listening, .proud, .sad,
                                       .orbit, .celebrate, .alerting, .confused, .surprised, .sleeping]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Silhouette").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 12), spacing: 10) {
                    ForEach(Array(SwarmeSilhouette.ids.enumerated()), id: \.offset) { index, id in
                        let names = SwarmePaletteData.names
                        VStack(spacing: 4) {
                            SwarmeAvatar(color: names[index % names.count], size: 64,
                                       state: SwarmeState.restingFace(for: id), silhouette: id, animated: false)
                            Text(id).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                Text("Stati (circle) e colori").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 14), spacing: 10) {
                    ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                        let names = SwarmePaletteData.names
                        VStack(spacing: 4) {
                            SwarmeAvatar(color: names[index % names.count], size: 64, state: state, animated: true, priority: true)
                            Text(state.rawValue).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                Text("Taglie").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach([16, 22, 24, 32, 42, 88] as [CGFloat], id: \.self) { size in
                        SwarmeAvatar(color: "white", size: size, state: .happy, silhouette: "antenna", animated: false)
                    }
                    ForEach([16, 22, 32, 88] as [CGFloat], id: \.self) { size in
                        SwarmeAvatar(color: "blue", size: size, state: .curious, animated: false)
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.app)
    }
}
