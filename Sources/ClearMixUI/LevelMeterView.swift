import SwiftUI

/// A compact level bar on a −60…0 dB scale.
struct LevelMeterView: View {
    let level: Float
    let muted: Bool
    var width: CGFloat = 50
    var height: CGFloat = 5
    /// Normal-fill color; red/orange still warn near the ceiling.
    var tint: Color = .accentColor

    private var fill: CGFloat {
        guard !muted, level > 0 else { return 0 }
        let db = 20 * log10(level)
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fill > 0.92 ? Color.red : (fill > 0.75 ? Color.orange : tint))
                    .frame(width: geometry.size.width * fill)
            }
        }
        .frame(width: width, height: height)
    }
}
