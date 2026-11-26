import SwiftUI

/// What sits in the menu bar: the account to run next and its headroom,
/// so the answer is readable without opening anything.
struct MenuBarLabel: View {
    let usages: [AccountUsage]
    /// The store's copy of the policy, not a fresh read of the file. The
    /// label redraws only when its inputs change, so reading the file here
    /// would leave an account excluded from the board named up here until
    /// the next refresh.
    let exclusions: Set<String>?

    var body: some View {
        if let best = Ranking.recommended(usages, excluding: exclusions), let headroom = Ranking.headroom(best) {
            HStack(spacing: 3) {
                Image(systemName: symbol(forUsed: 100 - headroom))
                Text("\(best.account.label.uppercased()) \(Int(headroom.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        } else if usages.isEmpty {
            Image(systemName: "circle.dashed")
        } else if usages.allSatisfy({ $0.failure != nil }) {
            // Every read failed. "spent" here would be a claim about the
            // accounts; this is a claim about our view of them.
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle")
                Text("no read").font(.system(size: 11, weight: .semibold))
            }
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
