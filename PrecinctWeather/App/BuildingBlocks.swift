import SwiftUI

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    /// Opaque pages (By-the-Numbers) pass solid:true — a frosted material needs a blur behind
    /// it, which only the precinct sheet has; on a plain grouped background a solid fill reads
    /// far cleaner. The sheet keeps the frosted look (default).
    var solid = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.serifDisplay(16, .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background {
            if solid {
                RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground))
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.06)))
    }
}

struct TwoPartyBar: View {
    let demShare: Double
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(Palette.dem).frame(width: geo.size.width * demShare)
                Rectangle().fill(Palette.rep)
            }
        }
        .frame(height: 12).clipShape(Capsule())
    }
}

struct BigStat: View {
    let value: String
    let label: String
    let delta: (String, Bool)?
    var valueColor: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(valueColor)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let delta {
                Text(delta.0).font(.caption2.bold())
                    .foregroundStyle(delta.1 ? .green : .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SmallStat: View {
    let title: String
    let value: String?
    init(_ title: String, _ value: String?) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(.headline.monospacedDigit()).contentTransition(.numericText())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
