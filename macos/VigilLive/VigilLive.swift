import ActivityKit
import SwiftUI
import VigilActivity
import VigilWire
import WidgetKit

/// A Mac's agents on the Lock Screen and in the Dynamic Island, drawn by
/// `VigilActivity`'s `AgentsGlance` (shared with the app's fixtures, which
/// photograph every face in both appearances: `bin/vigil-ios-fixtures`).
/// This file is the system's frame around it and nothing else.
///
/// Every word beyond the leading state arrives sealed to this phone
/// (`Agents`) and is opened here with the app's key; without it the
/// activity shows the state alone.
@main struct VigilLive: WidgetBundle {
    var body: some Widget { AgentsActivityWidget() }
}

struct AgentsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentsActivity.self) { context in
            let shown = AgentsShown(state: context.state, mac: context.attributes.mac, note: context.state.opened, stale: context.isStale)
            AgentsLockScreen(shown: shown)
                .widgetURL(shown.url)
        } dynamicIsland: { context in
            let shown = AgentsShown(state: context.state, mac: context.attributes.mac, note: context.state.opened, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { AgentsIslandBottom(shown: shown) }
            } compactLeading: {
                AgentsCompactLeading(shown: shown)
            } compactTrailing: {
                AgentsCompactTrailing(shown: shown)
            } minimal: {
                AgentsMinimal(shown: shown)
            }
            .widgetURL(shown.url)
            .keylineTint(shown.lead.tint)
        }
    }
}
