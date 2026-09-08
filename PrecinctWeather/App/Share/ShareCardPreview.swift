import SwiftUI
import UIKit
import Photos
import LinkPresentation
import CoreLocation
import PrecinctKit

// MARK: - Share preview
//
// Our screen in front of Apple's. The system activity sheet can't be restyled, but it doesn't
// have to be the first thing you see: this shows the finished card at full size on a dark
// backdrop, with the three things people actually want (send it, keep it, paste it). The system
// sheet only appears if they choose Share, and by then it is carrying a proper title and a real
// preview image instead of a filename and "PNG Image".
//
// It also fixes a smaller thing: you used to send the card without ever seeing it.

struct ShareCardPreview: View {
    let profile: PrecinctProfile
    let polygons: [PrecinctPolygon]
    let trend: [ElectionResult]
    let baseline: Baseline?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dts
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @State private var card: RenderedCard?
    /// Which action just succeeded, so its own button can report it. Confirmation belongs at the
    /// point of action: a toast floating over the middle of the screen makes you work out which
    /// of three buttons it was answering, and covers the thing you are trying to look at.
    @State private var done: Done?
    @State private var doneToken = 0
    /// Failures need more words than a button label holds, so they get their own line.
    @State private var problem: String?
    @State private var showActivity = false

    enum Done { case saved, copied }

    var body: some View {
        ZStack {
            backdrop.base.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                preview
                actions
            }
        }
        .task(id: colorScheme) {
            // Rendered here rather than before presenting: the map hero is a network fetch, and
            // a screen that appears instantly and fills in beats a button that hangs.
            card = nil
            done = nil
            problem = nil
            showActivity = false
            let rendered = await RenderedCard.make(
                profile: profile, polygons: polygons, trend: trend, baseline: baseline,
                colorScheme: colorScheme
            )
            guard !Task.isCancelled else { return }
            card = rendered
        }
        .sheet(isPresented: $showActivity) {
            if let card {
                ActivityView(source: ShareCardItemSource(card: card, title: title, profile: profile))
            }
        }
    }

    private var title: String {
        "\(precinctHeadline(profile)), \(countyDisplay(profile.borough)) \(profile.state)"
    }

    private var election: ShareCardElectionPresentation {
        ShareCardElectionPresentation(profile: profile)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(backdrop.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(backdrop.secondaryFill))
            }
            .accessibilityLabel("Close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// The whole card, scaled down to fit. It ends up smaller than it will be when it lands, but
    /// seeing all of it is the point of a preview: scrolling a tall card in a small window told
    /// you less about what you were about to send than one shrunken view of the finished thing.
    @ViewBuilder
    private var preview: some View {
        Group {
            if let card {
                Image(uiImage: card.image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.14), radius: 18, y: 8)
                    .accessibilityLabel("Share card for \(title). \(election.accessibilitySummary)")
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(backdrop.secondaryFill)
                    .aspectRatio(ShareCard.width / 900, contentMode: .fit)
                    .overlay { ProgressView().tint(backdrop.primary) }
                    .accessibilityLabel("Preparing the card")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let problem {
                Text(problem)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(backdrop.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Button { showActivity = true } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(backdrop.primary))
                    .foregroundStyle(backdrop.base)
            }
            // Large text needs the full width for each action label.
            let layout = dts.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                secondary(done == .saved ? "Saved" : "Save to Photos",
                          done == .saved ? "checkmark" : "square.and.arrow.down",
                          confirmed: done == .saved) { save() }
                secondary(done == .copied ? "Copied" : "Copy",
                          done == .copied ? "checkmark" : "doc.on.doc",
                          confirmed: done == .copied) { copy() }
            }
        }
        .buttonStyle(.plain)
        .disabled(card == nil)
        .opacity(card == nil ? 0.5 : 1)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private func secondary(_ label: String, _ icon: String, confirmed: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, dts.isAccessibilitySize ? 16 : 0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(confirmed ? backdrop.confirmedFill : backdrop.secondaryFill))
                .overlay(Capsule().strokeBorder(confirmed ? backdrop.confirmedRule : backdrop.rule))
                .foregroundStyle(backdrop.primary)
        }
        .animation(.easeOut(duration: 0.18), value: confirmed)
    }

    // MARK: Actions

    private func copy() {
        guard let card else { return }
        UIPasteboard.general.image = card.image
        confirm(.copied, spoken: "Card copied")
    }

    /// Add-only Photos access. The app never reads the library, which is why the Info.plist
    /// carries `NSPhotoLibraryAddUsageDescription` and nothing broader.
    private func save() {
        guard let card else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                // Name the fix, not just the failure.
                DispatchQueue.main.async {
                    report("Precinctly can't add to Photos. Turn it on in Settings, Privacy, Photos.")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: card.url)
            } completionHandler: { ok, _ in
                DispatchQueue.main.async {
                    if ok { confirm(.saved, spoken: "Card saved to Photos") }
                    else { report("Couldn't save the card to Photos.") }
                }
            }
        }
    }

    /// Confirms on the button that was pressed, and says so out loud: the visual swap alone
    /// tells a VoiceOver user nothing.
    private func confirm(_ action: Done, spoken: String) {
        problem = nil
        if hapticsEnabled { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        UIAccessibility.post(notification: .announcement, argument: spoken)
        doneToken += 1
        let token = doneToken
        withAnimation(.easeOut(duration: 0.18)) { done = action }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if token == doneToken { withAnimation(.easeIn(duration: 0.25)) { done = nil } }
        }
    }

    private func report(_ message: String) {
        done = nil
        UIAccessibility.post(notification: .announcement, argument: message)
        withAnimation(.easeOut(duration: 0.18)) { problem = message }
    }

    private var backdrop: Backdrop { Backdrop(colorScheme: colorScheme) }

    private struct Backdrop {
        let base: Color
        let primary: Color
        let secondary: Color
        let secondaryFill: Color
        let confirmedFill: Color
        let rule: Color
        let confirmedRule: Color

        init(colorScheme: ColorScheme) {
            if colorScheme == .dark {
                base = Color(red: 0.098, green: 0.106, blue: 0.129)
                primary = .white
                secondary = .white.opacity(0.8)
                secondaryFill = .white.opacity(0.12)
                confirmedFill = .white.opacity(0.26)
                rule = .white.opacity(0.18)
                confirmedRule = .white.opacity(0.55)
            } else {
                base = Color(red: 0.945, green: 0.941, blue: 0.925)
                primary = Color(red: 0.129, green: 0.145, blue: 0.184)
                secondary = primary.opacity(0.75)
                secondaryFill = primary.opacity(0.08)
                confirmedFill = primary.opacity(0.16)
                rule = primary.opacity(0.18)
                confirmedRule = primary.opacity(0.45)
            }
        }
    }
}

/// The rendered card plus the file backing it, so Share hands over a named PNG and Save writes
/// the same bytes rather than re-encoding a UIImage.
struct RenderedCard {
    let image: UIImage
    let url: URL

    @MainActor
    static func make(profile: PrecinctProfile, polygons: [PrecinctPolygon],
                     trend: [ElectionResult], baseline: Baseline?,
                     colorScheme: ColorScheme) async -> RenderedCard? {
        guard let image = await ShareCardRenderer.image(profile: profile, polygons: polygons,
                                                        trend: trend, baseline: baseline,
                                                        colorScheme: colorScheme),
              !Task.isCancelled,
              let url = ShareCardRenderer.write(image, for: profile) else { return nil }
        return RenderedCard(image: image, url: url)
    }
}

/// Gives the system sheet a real header: the precinct as the title and the card itself as the
/// preview image, instead of a filename and a byte count.
final class ShareCardItemSource: NSObject, UIActivityItemSource {
    private let card: RenderedCard
    private let title: String

    init(card: RenderedCard, title: String, profile: PrecinctProfile) {
        self.card = card
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { card.url }
    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? { card.url }
    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String { title }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: card.image)
        return metadata
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let source: UIActivityItemSource

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        // Actions that make no sense for a precinct card, or that this screen already offers.
        vc.excludedActivityTypes = [.assignToContact, .print, .addToReadingList, .saveToCameraRoll]
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
