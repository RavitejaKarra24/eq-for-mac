import SwiftUI

/// Interactive, log-frequency response editor.
///
/// Spectrum magnitudes are expected to be normalized to `0...1` and log-spaced
/// from 20 Hz to 20 kHz. Gain edits are reported by band index so the view model
/// can preserve a full parametric preset instead of replacing it with a lossy
/// graphic approximation.
struct EQCurveView: View {
    var gains: [Float]
    var frequencies: [Float]
    var spectrumMagnitudes: [Float] = []
    var range: ClosedRange<Float> = -12...12
    var isEditable = true
    var onGainChange: (Int, Float) -> Void = { _, _ in }
    var onResetBand: (Int) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredBand: Int?
    @State private var draggedBand: Int?

    private let plotInsets = EdgeInsets(top: 8, leading: 30, bottom: 18, trailing: 8)
    private let gridGains: [Float] = [-12, -6, 0, 6, 12]
    private let gridFrequencies: [Float] = [20, 100, 1_000, 10_000, 20_000]

    var body: some View {
        GeometryReader { geometry in
            let plot = plotRect(in: geometry.size)
            let points = bandPoints(in: plot)
            let curve = curvePath(points: points)

            ZStack {
                grid(in: plot)

                if !reduceMotion, !spectrumMagnitudes.isEmpty {
                    spectrumPath(in: plot)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.17),
                                    Color.accentColor.opacity(0.025),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .accessibilityHidden(true)
                }

                fillPath(from: curve, in: plot)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12),
                                Color.accentColor.opacity(0.015),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .accessibilityHidden(true)

                curve
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.82),
                                Color.accentColor,
                                Color.accentColor.opacity(0.82),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(
                        color: Color.accentColor.opacity(0.30),
                        radius: reduceMotion ? 0 : 4
                    )
                    .accessibilityHidden(true)

                ForEach(points.indices, id: \.self) { index in
                    node(at: points[index], index: index)
                }

                if let hoveredBand, points.indices.contains(hoveredBand) {
                    readout(for: hoveredBand, at: points[hoveredBand], in: plot)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: plot))
            .simultaneousGesture(resetGesture(in: plot))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredBand = nearestBand(to: location, in: plot)
                case .ended:
                    hoveredBand = nil
                }
            }
            .animation(
                reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.84),
                value: gains
            )
        }
        .accessibilityLabel("Interactive equalizer response")
        .accessibilityHint("Drag a point vertically to change gain. Double-click a point to reset it.")
    }

    // MARK: - Layers

    private func grid(in plot: CGRect) -> some View {
        ZStack {
            ForEach(gridGains, id: \.self) { gain in
                let y = yPosition(for: gain, in: plot)
                Path { path in
                    path.move(to: CGPoint(x: plot.minX, y: y))
                    path.addLine(to: CGPoint(x: plot.maxX, y: y))
                }
                .stroke(
                    Color.primary.opacity(gain == 0 ? 0.17 : 0.075),
                    style: StrokeStyle(
                        lineWidth: gain == 0 ? 1 : 0.75,
                        dash: gain == 0 ? [3, 4] : []
                    )
                )
                Text(gain == 0 ? "0" : "\(Int(gain))")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: plot.minX - 13, y: y)
            }

            ForEach(gridFrequencies, id: \.self) { frequency in
                let x = xPosition(for: frequency, in: plot)
                Path { path in
                    path.move(to: CGPoint(x: x, y: plot.minY))
                    path.addLine(to: CGPoint(x: x, y: plot.maxY))
                }
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.75)
                Text(frequencyLabel(frequency))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: x, y: plot.maxY + 10)
            }
        }
        .accessibilityHidden(true)
    }

    private func node(at point: CGPoint, index: Int) -> some View {
        let isHovered = hoveredBand == index
        return ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: isHovered ? 13 : 10, height: isHovered ? 13 : 10)
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: isHovered ? 2.5 : 2)
                .frame(width: isHovered ? 13 : 10, height: isHovered ? 13 : 10)
        }
        .position(point)
        .shadow(color: Color.accentColor.opacity(isHovered ? 0.42 : 0.18), radius: 3)
        .accessibilityElement()
        .accessibilityLabel("\(frequencyLabel(frequency(at: index))) hertz")
        .accessibilityValue(gainLabel(gain(at: index)))
        .accessibilityAdjustableAction { direction in
            guard isEditable else { return }
            let delta: Float = direction == .increment ? 0.5 : -0.5
            onGainChange(index, snapped(gain(at: index) + delta))
        }
    }

    private func readout(for index: Int, at point: CGPoint, in plot: CGRect) -> some View {
        let label = "\(frequencyLabel(frequency(at: index)))  \(gainLabel(gain(at: index)))"
        let estimatedWidth: CGFloat = 84
        let x = min(plot.maxX - estimatedWidth / 2, max(plot.minX + estimatedWidth / 2, point.x))
        let placeBelow = point.y < plot.minY + 28
        let y = placeBelow ? point.y + 22 : point.y - 22

        return Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .position(x: x, y: y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Interaction

    private func dragGesture(in plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard isEditable,
                      plot.contains(value.location)
                else { return }
                let index = draggedBand ?? nearestBand(to: value.location, in: plot)
                guard let index else { return }
                draggedBand = index
                hoveredBand = index
                onGainChange(index, gainValue(at: value.location.y, in: plot))
            }
            .onEnded { _ in
                draggedBand = nil
            }
    }

    private func resetGesture(in plot: CGRect) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard isEditable,
                      plot.contains(value.location),
                      let index = nearestBand(to: value.location, in: plot)
                else { return }
                onResetBand(index)
            }
    }

    private func nearestBand(to location: CGPoint, in plot: CGRect) -> Int? {
        guard !gains.isEmpty, !frequencies.isEmpty else { return nil }
        let points = bandPoints(in: plot)
        return points.indices.min { lhs, rhs in
            abs(points[lhs].x - location.x) < abs(points[rhs].x - location.x)
        }
    }

    private func gainValue(at y: CGFloat, in plot: CGRect) -> Float {
        guard plot.height > 0 else { return 0 }
        let normalized = Float(1 - ((y - plot.minY) / plot.height))
        let raw = range.lowerBound + normalized * (range.upperBound - range.lowerBound)
        let stepped = (raw * 2).rounded() / 2
        return snapped(min(range.upperBound, max(range.lowerBound, stepped)))
    }

    private func snapped(_ gain: Float) -> Float {
        abs(gain) <= 0.35 ? 0 : min(range.upperBound, max(range.lowerBound, gain))
    }

    // MARK: - Geometry

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: plotInsets.leading,
            y: plotInsets.top,
            width: max(1, size.width - plotInsets.leading - plotInsets.trailing),
            height: max(1, size.height - plotInsets.top - plotInsets.bottom)
        )
    }

    private func bandPoints(in plot: CGRect) -> [CGPoint] {
        let count = min(gains.count, frequencies.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            CGPoint(
                x: xPosition(for: frequencies[index], in: plot),
                y: yPosition(for: gains[index], in: plot)
            )
        }
    }

    private func xPosition(for frequency: Float, in plot: CGRect) -> CGFloat {
        let clamped = min(Float(20_000), max(Float(20), frequency))
        let normalized = (log10(Double(clamped)) - log10(20)) / (log10(20_000) - log10(20))
        return plot.minX + CGFloat(normalized) * plot.width
    }

    private func yPosition(for gain: Float, in plot: CGRect) -> CGFloat {
        let clamped = min(range.upperBound, max(range.lowerBound, gain))
        let span = max(0.001, range.upperBound - range.lowerBound)
        let normalized = CGFloat((clamped - range.lowerBound) / span)
        return plot.maxY - normalized * plot.height
    }

    private func curvePath(points: [CGPoint]) -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
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

    private func fillPath(from curve: Path, in plot: CGRect) -> Path {
        guard !gains.isEmpty else { return Path() }
        var fill = curve
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        fill.closeSubpath()
        return fill
    }

    private func spectrumPath(in plot: CGRect) -> Path {
        guard !spectrumMagnitudes.isEmpty else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for (index, magnitude) in spectrumMagnitudes.enumerated() {
            let fraction = spectrumMagnitudes.count == 1
                ? 0
                : CGFloat(index) / CGFloat(spectrumMagnitudes.count - 1)
            let x = plot.minX + fraction * plot.width
            let level = CGFloat(min(1, max(0, magnitude)))
            let y = plot.maxY - level * plot.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func frequency(at index: Int) -> Float {
        frequencies.indices.contains(index) ? frequencies[index] : 0
    }

    private func gain(at index: Int) -> Float {
        gains.indices.contains(index) ? gains[index] : 0
    }

    private func frequencyLabel(_ frequency: Float) -> String {
        if frequency >= 1_000 {
            let value = frequency / 1_000
            return value == floor(value)
                ? "\(Int(value))k"
                : String(format: "%.1fk", value)
        }
        return "\(Int(frequency))"
    }

    private func gainLabel(_ gain: Float) -> String {
        String(format: "%+.1f dB", gain)
    }
}
