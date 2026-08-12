import SwiftUI

// MARK: - Building blocks

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
