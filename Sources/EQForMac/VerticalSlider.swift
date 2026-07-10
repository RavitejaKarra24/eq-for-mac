import SwiftUI

/// Compact vertical fader for graphic EQ bands.
struct VerticalSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = -12...12
    var height: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            let trackWidth: CGFloat = 4
            let thumbSize: CGFloat = 14
            let usable = max(1, geo.size.height - thumbSize)
            let normalized = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            // Higher gain at the top
            let y = (1 - normalized) * usable

            ZStack(alignment: .top) {
                // Track
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: trackWidth, height: geo.size.height)
                    .frame(maxWidth: .infinity)

                // Fill from center (0 dB) toward thumb
                let midY = geo.size.height / 2
                let thumbCenterY = y + thumbSize / 2
                let fillTop = min(midY, thumbCenterY)
                let fillHeight = abs(midY - thumbCenterY)
                Capsule()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: trackWidth, height: max(2, fillHeight))
                    .offset(y: fillTop)
                    .frame(maxWidth: .infinity, alignment: .top)

                // Thumb
                Circle()
                    .fill(Color.primary)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .offset(y: y)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedY = min(max(0, drag.location.y - thumbSize / 2), usable)
                        let n = 1 - (clampedY / usable)
                        let raw = range.lowerBound + Float(n) * (range.upperBound - range.lowerBound)
                        // Snap to 0.5 dB
                        value = (raw * 2).rounded() / 2
                        value = min(range.upperBound, max(range.lowerBound, value))
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
            }
        }
        .frame(height: height)
        .help("Double-click to reset to 0 dB")
    }
}
