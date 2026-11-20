import SwiftUI
import VigilWire

/// The ticket and pane are the heading in the containing sheet.
struct MoveProofs: View {
    let answers: Move.MoveAnswers

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(answers.copy, answers.copyCheckpoint, "doc.on.doc")
            line(answers.release, answers.releaseCheckpoint, "desktopcomputer")
        }
    }

    private func line(_ words: String, _ checkpoint: String?, _ symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(words)
                if let checkpoint {
                    Text("Checkpoint " + checkpoint.prefix(12))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .help(checkpoint)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
