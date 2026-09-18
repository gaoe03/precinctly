import SwiftUI
import UIKit
import PrecinctKit

// MARK: - Helpers

enum Palette {
    static func lean(_ share: Double?) -> Color {
        Brand.leanColor(share)
    }
    /// Canonical party anchors for bars, labels, and legends. Every surface that colors
    /// "Democrat" or "Republican" as a category (not a data value) uses these, so the app
    /// has exactly one Democrat blue and one Republican red.
    static var dem: Color { lean(0.9) }
    static var rep: Color { lean(0.1) }
    /// One-hue ink ramp keyed by rank: largest group darkest.
    /// Lighter base in dark mode so low-opacity ranks stay visible over dark fills.
    static func rankTint(_ rank: Int) -> Color {
        let base = Brand.rankBase
        let opacity = max(0.35, 1.0 - Double(rank) * 0.16)
        return base.opacity(opacity)
    }
}

extension Baseline {
    /// The comparison area as a reader names it: "Alameda County" (not the city of Alameda),
    /// "Queens" for a borough, "NYC", "NY".
    var readerName: String {
        let parts = scope.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "county", parts.count == 3 { return countyDisplay(parts[2]) }
        return displayName
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
        return ("\(d >= 0 ? "+" : "−")\(abs(d)) \(abs(d) == 1 ? "pt" : "pts")" + (label.isEmpty ? "" : " vs \(label)"), d >= 0)
    }
    static func money(_ v: Int?, _ b: Int?, _ label: String) -> (String, Bool)? {
        // A top-coded income ($250k+) has no exact value, so no exact gap either.
        guard let v, let b, v < 250001 else { return nil }
        let d = v - b
        let k = Double(abs(d)) / 1000
        let amt = k >= 1 ? "$\(Int(k.rounded()))k" : "$\(abs(d))"
        return ("\(d >= 0 ? "+" : "−")\(amt)" + (label.isEmpty ? "" : " vs \(label)"), d >= 0)
    }
}
