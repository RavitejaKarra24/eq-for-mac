import SwiftUI

/// Smooth frequency-response curve drawn through graphic-EQ band gains.
/// Purely visual — gains are already in display order matching the faders above.
struct EQCurveView: View {
    var gains: [Float]
    var range: ClosedRange<Float> = -12...12

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let path = curvePath(in: geo.size)
            let fill = fillPath(from: path, in: geo.size)

            ZStack {
                // Soft fill under the curve
                fill
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18),
                                Color.accentColor.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // 0 dB reference
                Path { p in
                    let mid = geo.size.height * 0.5
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: geo.size.width, y: mid))
                }
                .stroke(
                    Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.10),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 4])
                )

                // Curve stroke
                path
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.85),
                                Color.accentColor,
                                Color.accentColor.opacity(0.85),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: Color.accentColor.opacity(0.35), radius: reduceMotion ? 0 : 4, y: 0)
            }
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.82), value: gains)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    private func points(in size: CGSize) -> [CGPoint] {
        guard gains.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let n = gains.count
        let span = max(0.001, range.upperBound - range.lowerBound)
        return gains.enumerated().map { i, g in
            let x = CGFloat(i) / CGFloat(n - 1) * size.width
            let clamped = min(range.upperBound, max(range.lowerBound, g))
            let normalized = CGFloat((clamped - range.lowerBound) / span)
            // Higher gain at the top
            let y = (1 - normalized) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func curvePath(in size: CGSize) -> Path {
        let pts = points(in: size)
        guard pts.count >= 2 else { return Path() }

        var path = Path()
        path.move(to: pts[0])

        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }

        // Catmull-Rom → cubic Bézier segments for a smooth studio curve
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(pts.count - 1, i + 2)]

            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func fillPath(from curve: Path, in size: CGSize) -> Path {
        var fill = curve
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        return fill
    }
}
