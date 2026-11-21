import SwiftUI

/// The Jax orb, drawn natively so it always fits the screen.
///
/// About a thousand points on a sphere, turned a little every frame and drawn
/// with depth: near points are bright and large, far points are faint. The
/// orb breathes with whoever is talking (you or Jax) through `meter`.
struct OrbView: View {
    let phase: Phase
    let meter: Meter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let points: [SIMD3<Double>] = {
        // Fibonacci sphere: an even spread with no visible seams or poles.
        let n = 2200
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = (1 - y * y).squareRoot()
            let a = golden * Double(i)
            return SIMD3(cos(a) * r, y, sin(a) * r)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityHidden(true)
    }

    private struct Style {
        var spin: Double      // turns per second
        var swell: Double     // how far the surface ripples
        var bright: Double
        var tint: Color
        var size: Double = 1
    }

    private var style: Style {
        switch phase {
        case .connecting: return Style(spin: 0.05, swell: 0.02, bright: 0.45, tint: Look.sky)
        case .offline: return Style(spin: 0.01, swell: 0.0, bright: 0.22, tint: Color(white: 0.6))
        case .ready: return Style(spin: 0.03, swell: 0.012, bright: 0.85, tint: Look.sky)
        case .hearing: return Style(spin: 0.05, swell: 0.05, bright: 1.0, tint: Look.sky)
        case .thinking: return Style(spin: 0.20, swell: 0.035, bright: 0.95, tint: Look.sky, size: 0.86)
        case .speaking: return Style(spin: 0.07, swell: 0.05, bright: 1.0, tint: Look.sky)
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let s = style
        let level = meter.value
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let half = min(size.width, size.height) / 2
        let calm = reduceMotion ? 0.25 : 1.0
        // Thinking pulls the orb inward and lets it breathe, so it reads as busy at a glance.
        let breath = phase == .thinking ? sin(time * 3.2) * 0.03 * calm : 0
        let radius = half * 0.70 * (s.size + breath) * (1 + level * 0.12 * calm)

        // Glow behind the sphere. Fades to nothing before the edge of the view,
        // so there is never a visible box around the orb.
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: s.tint.opacity(0.34 * s.bright + level * 0.2), location: 0),
                    .init(color: s.tint.opacity(0.13 * s.bright), location: 0.5),
                    .init(color: s.tint.opacity(0.03 * s.bright), location: 0.8),
                    .init(color: .clear, location: 1),
                ]),
                center: center, startRadius: 0, endRadius: half))

        let angle = time * s.spin * 2 * .pi * calm
        let tilt = 0.38 + sin(time * 0.21) * 0.08 * calm
        let (ca, sa, ct, st) = (cos(angle), sin(angle), cos(tilt), sin(tilt))
        let swell = (s.swell + level * 0.10) * calm
        let unit = size.width / 390

        var far = Path()
        var mid = Path()
        var near = Path()
        for (i, p) in Self.points.enumerated() {
            // A slow wave travelling over the surface, so the sphere feels alive.
            let wave = sin(p.y * 4 + time * 1.4 + Double(i % 5) * 0.6) * swell
            let k = 1 + wave
            let x = (p.x * ca + p.z * sa) * k
            let z0 = (-p.x * sa + p.z * ca) * k
            let y = (p.y * ct - z0 * st) * k
            let z = p.y * st + z0 * ct
            let depth = (z + 1) / 2 // 0 far ... 1 near
            // Perspective: near points spread wider and grow, far points gather and shrink.
            let scale = 0.78 + depth * 0.24
            let dot = (0.5 + depth * depth * 2.4) * unit
            let rect = CGRect(x: center.x + x * radius * scale - dot / 2,
                              y: center.y - y * radius * scale - dot / 2, width: dot, height: dot)
            if depth < 0.42 { far.addEllipse(in: rect) } else if depth < 0.76 { mid.addEllipse(in: rect) } else { near.addEllipse(in: rect) }
        }

        // Bloom: the same points, blurred and added as light. This is the
        // difference between dots on a screen and something that glows.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5 * unit))
            layer.blendMode = .plusLighter
            layer.fill(mid, with: .color(s.tint.opacity(0.55 * s.bright)))
            layer.fill(near, with: .color(s.tint.opacity(0.9 * s.bright)))
        }
        context.blendMode = .plusLighter
        context.fill(far, with: .color(s.tint.opacity(0.28 * s.bright)))
        context.fill(mid, with: .color(s.tint.opacity(0.62 * s.bright)))
        context.fill(near, with: .color(s.tint.opacity(0.95 * s.bright)))
        context.fill(near, with: .color(Color.white.opacity(0.45 * s.bright)))

        // Bright heart of the orb.
        let coreR = radius * ((phase == .thinking ? 0.55 : 0.34) + level * 0.3)
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - coreR, y: center.y - coreR, width: coreR * 2, height: coreR * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.5 * s.bright), s.tint.opacity(0.28 * s.bright), .clear]),
                center: center, startRadius: 0, endRadius: coreR))
    }
}
