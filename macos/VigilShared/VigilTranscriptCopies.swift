import SwiftUI
import VigilWire

/// What the addressed Mac last compared or heard about one conversation.
/// On every connection the home sends a complete snapshot of its recorded comparisons.
struct VigilTranscriptCopies: View {
    let conversation: ConversationRef
    let home: String
    let follow: (ConversationRef) async throws -> AsyncStream<Local.ProgressStep>
    @State private var observations: [TranscriptProgress]?
    @State private var problem: String?
    @State private var reading = false
    @State private var refresh = 0

    var body: some View {
        VigilTranscriptCopyReport(home: home, observations: observations, problem: problem, reading: reading) { refresh += 1 }
        .task(id: refresh) {
            reading = true
            defer { if !Task.isCancelled { reading = false } }
            do {
                let steps = try await follow(conversation)
                for await step in steps {
                    try Task.checkCancellation()
                    reading = false
                    switch step {
                    case .current(let rows):
                        observations = rows
                        problem = nil
                    case .waiting(let reason):
                        problem = reason
                    }
                }
                if !Task.isCancelled, problem == nil { problem = "The connection closed." }
            } catch {
                if !Task.isCancelled { problem = String(describing: error) }
            }
        }
    }
}

struct VigilTranscriptCopyReport: View {
    let home: String
    let observations: [TranscriptProgress]?
    let problem: String?
    let reading: Bool
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript copies").font(.headline)
                Spacer()
                if problem != nil {
                    Button("Reconnect", action: reload).disabled(reading)
                }
            }
            if let problem {
                Label("Updates from \(home) are unavailable. \(problem)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if let observations {
                if observations.isEmpty {
                    Text("\(home) has no verified copy report for this conversation.").foregroundStyle(.secondary)
                } else {
                    ForEach(observations, id: \.comparisonKey) { row in
                        VigilTranscriptCopyRow(row: row)
                    }
                }
            } else if reading {
                ProgressView("Reading reports from \(home)…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The destination's row in Bring Here is the same observation shown in details.
struct VigilTranscriptCopyRow: View {
    let row: TranscriptProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.copyMac).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(row.summary).fixedSize(horizontal: false, vertical: true)
            if let tip = row.sourceTip, row.reporterRoot != row.sourceRoot || row.reportedTip != tip {
                Text("Checkpoint from \(row.sourceMac) · \(bytes(tip.length))")
            }
            if let prefix = row.native {
                Text("Matching prefix in the conversation file · \(bytes(prefix.length))")
            }
            if let archive = row.archive {
                Text("Verified in the archive · \(bytes(archive.length))")
            }
            if let report = row.reportedAt, let reporter = row.reporterMac {
                let receiver = row.receivedOnMac
                if let tip = row.reportedTip {
                    clock("\(receiver) received \(reporter)’s report of \(bytes(tip.length))", at: report)
                } else {
                    clock("\(receiver) received the last report from \(reporter)", at: report)
                }
                if !row.peerOnline { Text("\(reporter) was offline when these details were read.") }
            }
            if let verified = row.verifiedAt, let verifier = row.verifiedByMac {
                clock("\(verifier) verified the prefix", at: verified)
            }
            if row.sourceTip != nil || row.native != nil || row.archive != nil || row.reportedTip != nil {
                DisclosureGroup("Checkpoint details") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let tip = row.sourceTip {
                            checkpoint("Source checkpoint", tip.length, tip.digest)
                        }
                        if let tip = row.reportedTip, tip != row.sourceTip {
                            checkpoint("Last reported tip", tip.length, tip.digest)
                        }
                        if let point = row.native {
                            checkpoint("Conversation file", point.length, point.digest)
                        }
                        if let point = row.archive {
                            checkpoint("Archive", point.length, point.digest)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func checkpoint(_ label: String, _ length: Int, _ digest: String?) -> some View {
        VStack(alignment: .leading) {
            Text("\(label) · \(length.formatted()) bytes")
            if let digest {
                Text("SHA-256 \(digest)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bytes(_ length: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(length), countStyle: .file)
    }

    private func clock(_ label: String, at seconds: Double) -> some View {
        let time = Date(timeIntervalSince1970: seconds)
        return Text("\(label) · \(time.formatted(date: .abbreviated, time: .shortened)) · \(time.formatted(.relative(presentation: .named)))")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
    }
}

private extension TranscriptProgress {
    var comparisonKey: String { sourceRoot + "/" + copyRoot }
}
