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
            return "No election data. The card uses neutral election text and omits the vote bar."
        case .partisan:
            return "Political lean (headline). The card includes the vote bar."
        }
    }

    init(profile: PrecinctProfile) {
        guard let share = profile.leanDemShare else {
            headline = "No election data"
            detail = nil
            footer = "Election data unavailable. 2020 Census and ACS."
            voteShare = nil
            tint = .neutral
            return
        }

        headline = profile.leanShort
        detail = profile.leanLabel.map { $0 + (profile.leanYear.map { " in \($0)" } ?? "") }
        footer = profile.leanYear.map { "\($0) presidential vote. 2020 Census and ACS." }
            ?? "Election year unavailable. 2020 Census and ACS."
        voteShare = share
        tint = .partisan(share)
    }
}
