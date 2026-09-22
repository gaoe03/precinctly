import Foundation
import PrecinctKit

/// A pure presentation contract shared by the rendered card and its tests. Election-null
/// profiles must never inherit a partisan label, color, or vote bar from the normal layout.
struct ShareCardElectionPresentation: Equatable {
    enum Tint: Equatable {
        case neutral
        case partisan(Double)
    }

    let headline: String
    let detail: String?
    let footer: String
    let voteShare: Double?
    let tint: Tint

    var showsVoteBar: Bool { voteShare != nil }

    var accessibilitySummary: String {
        switch tint {
        case .neutral:
            if let detail { return "\(headline). \(detail)." }
            return "No election data. Demographics are still available."
        case .partisan:
            return "Political lean \(headline)." + (detail.map { " \($0)." } ?? "")
        }
    }

    /// `trend` lets a precinct that missed the latest election name its latest result, the same
    /// as the card, instead of calling a chart of real results "no election data".
    init(profile: PrecinctProfile, trend: [ElectionResult] = []) {
        guard let share = profile.leanDemShare else {
            if let latest = trend.last(where: { $0.demShare != nil }), let s = latest.demShare, latest.year < 2024 {
                headline = "No 2024 result"
                detail = "Latest result \(Metric.lean.format(s)) in \(latest.year)"
                footer = "\(latest.year) presidential vote, the latest available. 2020 Census and American Community Survey."
            } else {
                headline = "No election data"
                detail = nil
                footer = "Election data unavailable. 2020 Census and American Community Survey."
            }
            voteShare = nil
            tint = .neutral
            return
        }

        headline = profile.leanShort
        detail = profile.leanLabel.map { $0 + (profile.leanYear.map { " in \($0)" } ?? "") }
        footer = profile.leanYear.map { "\($0) presidential vote. 2020 Census and American Community Survey." }
            ?? "Election year unavailable. 2020 Census and American Community Survey."
        voteShare = share
        tint = .partisan(share)
    }
}
