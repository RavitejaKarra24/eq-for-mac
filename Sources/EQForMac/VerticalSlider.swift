import SwiftUI

/// Compact vertical fader for graphic EQ bands — studio-console style.
struct VerticalSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = -12...12
    var height: CGFloat = 120
    var isActive: Bool = true

    @State private var isHovering = false
    @State private var isDragging = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var normalized: CGFloat {
        let span = max(0.001, range.upperBound - range.lowerBound)
        return CGFloat((value - range.lowerBound) / span)
    }

    private var isBoost: Bool { value > 0.05 }
    private var isCut: Bool { value < -0.05 }
    private var isNearZero: Bool { abs(value) < 0.05 }

    private var fillColor: Color {
        if isBoost { return Color.accentColor }
        if isCut { return Color.orange.opacity(0.9) }
        return Color.secondary.opacity(0.45)
    }

    var body: some View {
        GeometryReader { geo in
            let trackWidth: CGFloat = (isHovering || isDragging) ? 5 : 4
            let thumbW: CGFloat = (isHovering || isDragging) ? 16 : 14
            let thumbH: CGFloat = (isHovering || isDragging) ? 10 : 9
            let usable = max(1, geo.size.height - thumbH)
            let y = (1 - normalized) * usable
            let midY = geo.size.height / 2
            let thumbCenterY = y + thumbH / 2

            ZStack(alignment: .top) {
                // Track background
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10),
                                Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                    .frame(width: trackWidth, height: geo.size.height)
                    .frame(maxWidth: .infinity)

                // Subtle tick marks at ±6 dB and 0
                ForEach([-6.0, 0.0, 6.0], id: \.self) { db in
                    let n = CGFloat((Float(db) - range.lowerBound) / (range.upperBound - range.lowerBound))
                    let tickY = (1 - n) * geo.size.height
                    Capsule()
                        .fill(Color.primary.opacity(db == 0 ? 0.22 : 0.10))
                        .frame(width: db == 0 ? 10 : 7, height: 1)
                        .offset(y: tickY)
                        .frame(maxWidth: .infinity, alignment: .top)
                }

                // Fill from center (0 dB) toward thumb
                let fillTop = min(midY, thumbCenterY)
                let fillHeight = abs(midY - thumbCenterY)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                fillColor.opacity(isActive ? 0.95 : 0.45),
                                fillColor.opacity(isActive ? 0.55 : 0.25),
                            ],
                            startPoint: isBoost ? .bottom : .top,
                            endPoint: isBoost ? .top : .bottom
                        )
                    )
                    .frame(width: trackWidth, height: max(isNearZero ? 0 : 2, fillHeight))
                    .offset(y: fillTop)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .shadow(color: isActive && !isNearZero ? fillColor.opacity(0.35) : .clear, radius: 3, y: 0)

                // Thumb — capsule like a mixer fader cap
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.95), Color.white.opacity(0.82)]
                                : [Color.white, Color(nsColor: .windowBackgroundColor)]
                            ,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(isDragging || isHovering ? 0.28 : 0.14),
                                lineWidth: 0.5
                            )
                    )
                    .overlay(alignment: .center) {
                        // Center grip line
                        Capsule()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: thumbW - 6, height: 1)
                    }
                    .frame(width: thumbW, height: thumbH)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: isDragging ? 3 : 1.5, y: 1)
                    .offset(y: y)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging { isDragging = true }
                        let clampedY = min(max(0, drag.location.y - thumbH / 2), usable)
                        let n = 1 - (clampedY / usable)
                        let raw = range.lowerBound + Float(n) * (range.upperBound - range.lowerBound)
                        // Snap to 0.5 dB
                        var snapped = (raw * 2).rounded() / 2
                        snapped = min(range.upperBound, max(range.lowerBound, snapped))
                        // Magnetic snap to 0 dB
                        if abs(snapped) <= 0.5, abs(raw) < 0.35 {
                            snapped = 0
                        }
                        value = snapped
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
            }
            .onHover { hovering in
                isHovering = hovering
            }
        }
        .frame(height: height)
        .opacity(isActive ? 1 : 0.55)
        .help("Drag to adjust · double-click for 0 dB")
        .accessibilityLabel("Band gain")
        .accessibilityValue(Text(String(format: "%+.1f decibels", value)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(range.upperBound, value + 0.5)
            case .decrement:
                value = max(range.lowerBound, value - 0.5)
            @unknown default:
                break
            }
        }
    }
}
