import SwiftUI

// MARK: - Helpers

enum Palette {
    private static func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
        Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }
    static func lean(_ share: Double?) -> Color {
        guard let s = share else { return .gray }
        let red = (0.85, 0.16, 0.16), purple = (0.55, 0.25, 0.7), blue = (0.13, 0.4, 0.9)
        let t = max(0, min(1, s))
        return t >= 0.5 ? lerp(purple, blue, (t - 0.5) * 2) : lerp(red, purple, t * 2)
    }
    /// Restrained single-hue (slate/indigo) ramp keyed by rank: largest group darkest.
    static func rankTint(_ rank: Int) -> Color {
        let base = Color(red: 0.36, green: 0.40, blue: 0.58)   // muted slate-indigo
        let opacity = max(0.35, 1.0 - Double(rank) * 0.16)
        return base.opacity(opacity)
    }
}

enum Fmt {
    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func money(_ v: Int) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
    /// Household income with the ACS top-code shown honestly as "$250k+" (sentinel 250001), else exact.
    static func incomeTopCoded(_ v: Int) -> String { v >= 250001 ? "$250k+" : money(v) }
    /// Compact count: 20.2M, 3.4k, 850. One decimal, trailing ".0" dropped.
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return trimmed(d / 1_000_000) + "M" }
        if d >= 1_000 { return trimmed(d / 1_000) + "k" }
        return "\(n)"
    }
    private static func trimmed(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

enum Delta {
    static func points(_ v: Double?, _ b: Double?, _ label: String) -> (String, Bool)? {
        guard let v, let b else { return nil }
        let d = Int(((v - b) * 100).rounded())
        return ("\(d >= 0 ? "+" : "−")\(abs(d)) vs \(label)", d >= 0)
    }
    static func money(_ v: Int?, _ b: Int?, _ label: String) -> (String, Bool)? {
        guard let v, let b else { return nil }
        let d = v - b
        let k = Double(abs(d)) / 1000
        let amt = k >= 1 ? "$\(Int(k.rounded()))k" : "$\(abs(d))"
        return ("\(d >= 0 ? "+" : "−")\(amt) vs \(label)", d >= 0)
    }
}
