import SwiftUI

enum RenderDialGeometry {
    static func fraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    static func point(_ radius: Double, fraction: Double) -> CGPoint {
        let radians = (150 + 240 * fraction) * .pi / 180
        return CGPoint(x: 82 + radius * cos(radians), y: 76 + radius * sin(radians))
    }
}

private struct RenderDialArc: Shape {
    var fraction: Double
    var animatableData: Double { get { fraction } set { fraction = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: 82, y: 76), radius: 49, startAngle: .degrees(150), endAngle: .degrees(150 + 240 * fraction), clockwise: false)
        return path
    }
}

private struct RenderDialNeedle: Shape {
    var fraction: Double
    var animatableData: Double { get { fraction } set { fraction = newValue } }
    func path(in rect: CGRect) -> Path {
        let angle = (150 + 240 * fraction) * .pi / 180
        let center = CGPoint(x: 82, y: 76)
        var path = Path()
        path.move(to: RenderDialGeometry.point(44, fraction: fraction))
        path.addLine(to: CGPoint(x: center.x - 3 * sin(angle), y: center.y + 3 * cos(angle)))
        path.addLine(to: CGPoint(x: center.x - 9 * cos(angle), y: center.y - 9 * sin(angle)))
        path.addLine(to: CGPoint(x: center.x + 3 * sin(angle), y: center.y - 3 * cos(angle)))
        path.closeSubpath()
        return path
    }
}

struct RenderDial: View {
    let progress: Double?
    let live: Bool
    var width: CGFloat = 164
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var fraction: Double? { RenderDialGeometry.fraction(progress) }
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.045)], center: .topLeading, startRadius: 0, endRadius: 98))
                .overlay { Circle().strokeBorder(.white.opacity(0.24), lineWidth: 0.7) }
                .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
                .frame(width: 98, height: 98).position(x: 82, y: 76)
            RenderDialArc(fraction: 1).stroke(RenderStyle.secondary.opacity(0.23), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            if let fraction {
                RenderDialArc(fraction: fraction).stroke(RenderStyle.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            Canvas { context, _ in
                for index in 0...20 {
                    let value = Double(index) / 20, major = index % 5 == 0
                    var tick = Path()
                    tick.move(to: RenderDialGeometry.point(56, fraction: value))
                    tick.addLine(to: RenderDialGeometry.point(major ? 63 : 59, fraction: value))
                    context.stroke(tick, with: .color(RenderStyle.secondary.opacity(major ? 0.8 : 0.38)), lineWidth: major ? 1.2 : 0.7)
                }
                for value in [0.0, 0.5, 1.0] {
                    let label = Text(String(Int(value * 100))).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(RenderStyle.secondary)
                    context.draw(label, at: value == 0.5 ? CGPoint(x: 82, y: 5) : RenderDialGeometry.point(73, fraction: value))
                }
            }
            if let fraction {
                RenderDialNeedle(fraction: fraction).fill(RenderStyle.ink)
                    .shadow(color: .black.opacity(0.28), radius: 1, x: 1, y: 1)
            }
            Circle().fill(RenderStyle.secondary).frame(width: 12, height: 12).position(x: 82, y: 76)
            Circle().fill(fraction == nil ? RenderStyle.secondary.opacity(0.4) : RenderStyle.blue).frame(width: 6, height: 6).position(x: 82, y: 76)
            Text(fraction.map { String(format: "%.0f %%", $0 * 100) } ?? "—")
                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(RenderStyle.ink).position(x: 82, y: 123)
        }.frame(width: 164, height: 140)
            .animation(live && !reduceMotion ? .easeOut(duration: 0.42) : nil, value: fraction)
            .scaleEffect(width / 164).frame(width: width, height: width * 140 / 164)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Progression de zéro à cent pour cent")
            .accessibilityValue(fraction.map { String(format: "%.0f pour cent", $0 * 100) } ?? "Progression indéterminée")
    }
}

struct DashboardProgressView: View {
    let title: String
    let count: Int?
    let progress: RenderProgress?
    let isFresh: Bool
    let activity: RenderActivity
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(isFresh ? "Relevé récent" : "Dernier relevé").font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
            }
            HStack(spacing: 10) {
                RenderDial(progress: progress?.fraction, live: isFresh && activity == .running, width: compact ? 80 : 164)
                VStack(alignment: .leading, spacing: 5) {
                    Text(progress?.countLabel ?? count.flatMap { $0 >= 0 ? "\($0) signalés" : nil } ?? "—")
                        .font(.system(size: compact ? 21 : 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(progress.map { "Restant : \($0.total - $0.completed)" } ?? "Total indéterminé")
                        .font(.system(size: 11)).foregroundStyle(RenderStyle.secondary).monospacedDigit()
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 18, shadow: 3)
    }
}

struct CompactCatalogIndicator: View {
    let job: RenderDashboardJob
    var body: some View {
        RenderDial(progress: job.rawProgress?.fraction, live: job.isFresh && !job.retainedHistorical && job.activity == .running, width: 72)
            .accessibilityHidden(true)
    }
}
