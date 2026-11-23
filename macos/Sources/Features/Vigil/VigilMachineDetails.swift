import MachineStateViews
import MachineStates
import SwiftUI

/// A Mac's facts, set out in the popover its sidebar header opens: its
/// power whole (a battery's charge large, then every reading), its disk and
/// its heat, each by swift-utils' one view for a fact
/// (`MachineState.Details`). Memory, processors and graphics are left out:
/// a snapshot is written when the system posts a change, so between changes
/// those three are as they stood then, and this would say them as now.
/// When the Mac's facts are not read, or do not read here, it says that in
/// their place.
struct VigilMachineDetails: View {
    enum Shown: Equatable {
        case snapshot(MachineState.Snapshot)
        case words(String)
    }

    let shown: Shown

    init(_ shown: Shown) { self.shown = shown }

    var body: some View {
        Group {
            switch shown {
            case .snapshot(let snapshot):
                VStack(alignment: .leading, spacing: 14) {
                    MachineState.Details(snapshot)
                    if snapshot.disk != nil {
                        Divider()
                        MachineState.Details(snapshot, of: .disk)
                    }
                    Divider()
                    MachineState.Details(snapshot, of: .heat)
                }
            case .words(let words):
                Text(words)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        // Wide enough for a battery's capacity line whole
        // ("92% of design (5600 of 6075 mAh)").
        .frame(width: 340, alignment: .leading)
    }
}
