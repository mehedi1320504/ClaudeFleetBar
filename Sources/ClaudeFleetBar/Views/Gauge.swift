import SwiftUI

/// A ring showing how much of a window is consumed.
struct UsageRing: View {
    let used: Double
    var size: CGFloat = 54
    var lineWidth: CGFloat = 6

    private var fraction: Double { min(max(used / 100, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        colors: [Palette.tint(forUsed: used).opacity(0.75),
                                 Palette.tint(forUsed: used)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.5), value: fraction)

            Text(Format.percent(used))
                .font(.numeric(size * 0.30, .bold))
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
    }
}

/// A slim horizontal meter, for the compact rows.
struct UsageBar: View {
    let used: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(Palette.tint(forUsed: used))
                    .frame(width: max(3, geo.size.width * min(max(used / 100, 0), 1)))
                    .animation(.smooth(duration: 0.5), value: used)
            }
        }
        .frame(height: height)
    }
}
