import SwiftUI

/// What sits in the menu bar: the account to run next and its headroom,
/// so the answer is readable without opening anything.
struct MenuBarLabel: View {
    let usages: [AccountUsage]

    var body: some View {
        if let best = Ranking.recommended(usages), let headroom = Ranking.headroom(best) {
            HStack(spacing: 3) {
                Image(systemName: symbol(forUsed: 100 - headroom))
                Text("\(best.account.label.uppercased()) \(Int(headroom.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        } else if usages.isEmpty {
            Image(systemName: "circle.dashed")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("spent").font(.system(size: 11, weight: .semibold))
            }
        }
    }

    /// A filled ring that empties as the fleet's best account is consumed —
    /// legible in the menu bar at a glance, where colour alone is not.
    private func symbol(forUsed used: Double) -> String {
        switch used {
        case ..<25: "circle.fill"
        case ..<50: "circle.righthalf.filled"
        case ..<75: "circle.lefthalf.filled"
        case ..<100: "circle.dotted"
        default: "circle"
        }
    }
}
