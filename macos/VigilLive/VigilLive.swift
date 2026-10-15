import ActivityKit
import SwiftUI
import VigilActivity
import VigilWire
import WidgetKit

/// A followed session on the Lock Screen and in the Dynamic Island: its
/// face and name (the phone's own), its Mac, and what it is doing as its
/// Mac last pushed (blocked asks for you, working, done, idle) with how
/// long. A tap opens the session on the pane that asks. Laid out to
/// Apple's Live Activity guidance: 14 pt margins, the title first.
@main struct VigilLive: WidgetBundle {
    var body: some Widget { SessionActivityWidget() }
}

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivity.self) { context in
            LockScreen(attributes: context.attributes, state: context.state)
                .padding(14)
                .activitySystemActionForegroundColor(.secondary)
                .widgetURL(context.attributes.url)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Face(attributes: context.attributes).padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Since(state: state).font(.caption.weight(.semibold)).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.label).font(.headline).lineLimit(1)
                        Status(state: state)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Face(attributes: context.attributes)
            } compactTrailing: {
                Dot(state: state.state)
            } minimal: {
                Dot(state: state.state)
            }
            .widgetURL(context.attributes.url)
            .keylineTint(state.state.tint)
        }
    }
}

/// Header, the session, what it does.
private struct LockScreen: View {
    let attributes: SessionActivity
    let state: SessionActivity.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.footnote).foregroundStyle(.secondary)
                Text(attributes.mac).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Since(state: state).font(.footnote.weight(.semibold))
            }
            HStack(spacing: 8) {
                if let emoji = attributes.emoji { Text(emoji).font(.title3) }
                Text(attributes.label).font(.headline).lineLimit(1)
            }
            Status(state: state)
        }
    }
}

/// The session's face, or its first letter.
private struct Face: View {
    let attributes: SessionActivity
    var body: some View {
        if let emoji = attributes.emoji {
            Text(emoji)
        } else {
            Text(attributes.label.prefix(1).uppercased()).font(.caption.weight(.bold))
        }
    }
}

/// What the session does, in words and color.
private struct Status: View {
    let state: SessionActivity.ContentState
    var body: some View {
        Label {
            Text(state.state.words).font(.subheadline.weight(.medium))
        } icon: {
            Dot(state: state.state)
        }
    }
}

private struct Dot: View {
    let state: SessionState
    var body: some View {
        Circle().fill(state.tint).frame(width: 9, height: 9)
    }
}

/// How long it has been doing it, ticking on its own.
private struct Since: View {
    let state: SessionActivity.ContentState
    var body: some View {
        Text(Date(timeIntervalSince1970: state.since), style: .relative)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(state.state.tint)
    }
}

extension SessionState {
    /// The sidebar's colors: blocked asks (orange), working (yellow), done
    /// (teal), idle (quiet).
    var tint: Color {
        switch self {
        case .blocked: .orange
        case .working: .yellow
        case .done: .teal
        case .idle: .secondary
        }
    }

    var words: String {
        switch self {
        case .blocked: "Waiting for you"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
    }
}
