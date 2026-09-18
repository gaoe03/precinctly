import SwiftUI
import UIKit
import CoreText

// MARK: - Design system
//
// Precinctly's visual language in one place. It borrows from the results page a city paper prints
// the morning after an election: heavy figures, plain labels, one rule under each heading.
//
// - Type: Libre Franklin in every weight (bundled, OFL). Hierarchy comes from weight and size.
// - Color: party only. Everything else is ink on the system background, plus green and orange
//   for money and education deltas.
// - Structure: a title with one rule under it. No gray cards, no capsules. Small controls are
//   8 pt rounded rectangles, full-width buttons 12 pt, sheets close with an X.
//
// The app and the widget extension both read these values, so both processes register the
// bundled fonts (see `registerFonts`).

enum Brand {
    // MARK: fonts

    /// Registers the bundled Libre Franklin files once per process. Called lazily from every
    /// font accessor, so the widget extension (which never runs the app's init) gets them too.
    private static let fontsRegistered: Bool = {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Navigation titles in the display face. Call once at app launch.
    static func configureAppearance() {
        _ = fontsRegistered
        // An opaque bar in the page color with no hairline under it. Headings carry their own
        // rule, so a second line under the bar read as a stray divider.
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = .systemBackground
        bar.shadowColor = .clear
        if let font = UIFont(name: display[.bold]!, size: 17) { bar.titleTextAttributes = [.font: font] }
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }

    private static let display: [Font.Weight: String] = [
        .regular: "LibreFranklin-Regular", .medium: "LibreFranklin-Medium", .semibold: "LibreFranklin-Bold",
        .bold: "LibreFranklin-ExtraBold", .heavy: "LibreFranklin-Black", .black: "LibreFranklin-Black",
    ]
    private static let text: [Font.Weight: String] = [
        .regular: "LibreFranklin-Regular", .medium: "LibreFranklin-Medium", .semibold: "LibreFranklin-SemiBold",
        .bold: "LibreFranklin-Bold", .heavy: "LibreFranklin-ExtraBold",
    ]
    /// Stat figures run one step heavier than display text of the same nominal weight.
    private static let figures: [Font.Weight: String] = [
        .regular: "LibreFranklin-SemiBold", .medium: "LibreFranklin-Bold", .semibold: "LibreFranklin-ExtraBold",
        .bold: "LibreFranklin-ExtraBold", .heavy: "LibreFranklin-Black",
    ]

    private static func pick(_ map: [Font.Weight: String], _ weight: Font.Weight) -> String {
        _ = fontsRegistered
        if let name = map[weight] { return name }
        let order: [Font.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let i = order.firstIndex(of: weight) ?? 3
        // Nearest available weight, preferring heavier.
        for d in 0..<order.count {
            if i + d < order.count, let n = map[order[i + d]] { return n }
            if i - d >= 0, let n = map[order[i - d]] { return n }
        }
        return map[.regular]!
    }

    /// A size scaled with Dynamic Type, capped at 1.4x so fixed-height areas never overflow.
    /// Views use it through `brandScaledDisplay` and `brandScaledFigure`, which pass their own
    /// text size. `UIFontMetrics.default` alone reads `UITraitCollection.current`, which is not
    /// the view's text size during a SwiftUI update: figures laid out at extra small at the
    /// largest text size, and the card's grid then clipped the labels under them.
    static func scaledSize(_ size: CGFloat, for dts: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dts))
        return min(UIFontMetrics.default.scaledValue(for: size, compatibleWith: traits), size * 1.4)
    }

    static func displayFont(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(pick(display, weight), fixedSize: size)
    }

    static func figureFont(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(pick(figures, weight), fixedSize: size)
    }

    /// Fixed size text, for the share card and widgets, which must not follow Dynamic Type.
    static func textFixed(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(pick(text, weight), fixedSize: size)
    }

    static func textFont(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .custom(pick(text, weight), size: baseSize(style), relativeTo: style)
    }

    /// Method and source notes: 11 pt, scaling with Dynamic Type from the caption2 size.
    static var noteFont: Font {
        _ = fontsRegistered
        return .custom("LibreFranklin-Regular", size: 11, relativeTo: .caption2)
    }

    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }

    // MARK: surfaces and lines

    private static func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    static let surface = Color(.systemBackground)
    /// Controls tint. Mid gray in dark mode so a switch's white knob stays visible on its track.
    static let tint = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.07, alpha: 1) }
    /// Thin lines between rows and blocks. Brighter in dark mode, where the system separator
    /// nearly disappears on black.
    static let hairline = dyn(UIColor(white: 0, alpha: 0.12), UIColor(white: 1, alpha: 0.2))
    /// The rule under a heading. Never pure white in dark mode: a white stroke on near-black is
    /// the loudest thing on screen.
    static let ruleInk = dyn(UIColor(white: 0.07, alpha: 0.9), UIColor(white: 1, alpha: 0.32))
    /// Money and education deltas. Darker in light mode so they pass 4.5 to 1 on white.
    static let deltaUp = dyn(UIColor(red: 0.12, green: 0.51, blue: 0.24, alpha: 1), UIColor(red: 0.36, green: 0.78, blue: 0.47, alpha: 1))
    static let deltaDown = dyn(UIColor(red: 0.70, green: 0.33, blue: 0.0, alpha: 1), UIColor(red: 1.0, green: 0.62, blue: 0.26, alpha: 1))
    /// Base of the one-hue rank bars (race shares).
    static let rankBase = dyn(UIColor(white: 0.12, alpha: 1), UIColor(white: 0.72, alpha: 1))

    static let sheetCorner: CGFloat = 22
    static let heroSize: CGFloat = 56
    static let chartWidth: CGFloat = 34
    static let barHeight: CGFloat = 10

    // MARK: map

    static let mapFill = 0.7
    static let mapStrokeWidth: CGFloat = 2.5
    /// Selected-precinct outline: ink, so it reads over any lean color.
    static let mapStroke = dyn(UIColor(white: 0.07, alpha: 1), UIColor(white: 1, alpha: 0.9))

    // MARK: party color

    private static let dem = (0.16, 0.36, 0.67)
    private static let even = (0.47, 0.27, 0.58)
    private static let rep = (0.78, 0.06, 0.18)

    /// Exact margins (the hero figure, the map, trajectory bars) use a continuous scale from
    /// Democratic blue through purple to Republican red. One set of values in both appearances,
    /// so Solid D is always the strongest blue.
    static func leanColor(_ share: Double?) -> Color {
        guard let s = share else { return .gray }
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        let t = max(0, min(1, s))
        let c = t >= 0.5 ? mix(even, dem, (t - 0.5) * 2) : mix(rep, even, t * 2)
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    // MARK: shapes

    /// Small inline controls: chips, menus, icon buttons.
    static let chipShape = AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    static let iconShape = chipShape
    /// Full-width buttons.
    static let buttonShape = AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    static let buttonBorderShape = ButtonBorderShape.roundedRectangle(radius: 12)
}

extension Font {
    /// Method and source notes. One size everywhere, a step under captions.
    static var brandNote: Font { Brand.noteFont }

    /// Text style in the brand's text face at a given weight.
    static func bt(_ style: Font.TextStyle, _ weight: Font.Weight) -> Font {
        Brand.textFont(style, weight)
    }
    static func bt(_ style: Font.TextStyle) -> Font {
        Brand.textFont(style, style == .headline ? .semibold : .regular)
    }
}

/// The display and figure faces at a size that follows the view's own Dynamic Type setting.
struct BrandScaledFont: ViewModifier {
    enum Face { case display, figures, symbol }
    @Environment(\.dynamicTypeSize) private var dts
    let size: CGFloat
    let weight: Font.Weight
    var face: Face = .display
    func body(content: Content) -> some View {
        let scaled = Brand.scaledSize(size, for: dts)
        switch face {
        case .display: content.font(Brand.displayFont(scaled, weight))
        case .figures: content.font(Brand.figureFont(scaled, weight))
        case .symbol: content.font(.system(size: scaled, weight: weight))
        }
    }
}

extension View {
    /// The display face, scaled with Dynamic Type and capped at 1.4x.
    func brandScaledDisplay(_ size: CGFloat, _ weight: Font.Weight) -> some View {
        modifier(BrandScaledFont(size: size, weight: weight, face: .display))
    }

    /// The figure face, scaled with Dynamic Type and capped at 1.4x.
    func brandScaledFigure(_ size: CGFloat, _ weight: Font.Weight) -> some View {
        modifier(BrandScaledFont(size: size, weight: weight, face: .figures))
    }
}

// MARK: - Section header chrome

/// Card section header: the title with one rule under it, and an optional accessory (the
/// comparison menu) on the title line.
struct BrandSectionHeader<Accessory: View>: View {
    let title: String
    let stacked: Bool
    /// When set, the title and a chevron become a button.
    var onTap: (() -> Void)? = nil
    @ViewBuilder var accessory: Accessory
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if stacked {
                VStack(alignment: .leading, spacing: 6) { label; trailingAccessory }
            } else {
                // Title and accessory share a line when they fit. A long comparison name
                // ("vs Alameda County") drops under the title instead of wrapping it, and
                // stays on the right either way.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { label.fixedSize(); Spacer(minLength: 4); accessory }
                    VStack(alignment: .leading, spacing: 6) { label; trailingAccessory }
                }
            }
            Rectangle().fill(Brand.ruleInk).frame(height: 1.5)
        }
    }
    private var trailingAccessory: some View {
        accessory.frame(maxWidth: .infinity, alignment: .trailing)
    }
    @ViewBuilder private var label: some View {
        let text = HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).brandScaledDisplay(19, .bold)
            if onTap != nil {
                // Scales with the title, under the same cap.
                Image(systemName: "chevron.right")
                    .modifier(BrandScaledFont(size: 12, weight: .bold, face: .symbol))
                    .foregroundStyle(.secondary)
            }
        }
        if let onTap {
            Button(action: onTap) { text.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens By the Numbers")
        } else {
            text
        }
    }
}

/// List section header in the same style, opaque so pinned headers never show rows through them.
struct BrandListHeader: View {
    let title: String
    var size: CGFloat = 17
    init(_ title: String, size: CGFloat = 17) { self.title = title; self.size = size }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).brandScaledDisplay(size, .bold).foregroundStyle(Color(uiColor: .label))
            Rectangle().fill(Brand.ruleInk).frame(height: 1.5)
        }
        .textCase(nil)
        .padding(.top, 10).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface)
    }
}

extension View {
    /// Plain lists grouped by spacing and the header rule. No row or section separators, since a
    /// hairline under every row and another under the last row right above the next rule read as
    /// clutter. Long ranked lists opt back in with `brandRowRule()`.
    func brandList() -> some View {
        self.listStyle(.plain)
            .listSectionSeparator(.hidden)
            .listRowSeparator(.hidden)
            .scrollContentBackground(.hidden)
            .background(Brand.surface)
    }

    /// Hairlines between rows of a long list (rankings, counties, search results). The last row
    /// gets none, so no line sits at the bottom of a section.
    func brandRowRule(last: Bool = false) -> some View {
        self.listRowSeparator(last ? .hidden : .visible, edges: .bottom).listRowSeparator(.hidden, edges: .top)
            .listRowSeparatorTint(Brand.hairline)
    }

    /// Toolbar icon button: an 8 pt chip instead of the system glass circle.
    func brandToolbarChip() -> some View {
        self.frame(width: 36, height: 36)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// A solid top bar in the page color. iOS 26 otherwise fades rows into a blur under the bar,
    /// which cut headers and charts off at odd heights.
    @ViewBuilder func brandSolidBar() -> some View {
        if #available(iOS 26.0, *) {
            self.toolbarBackground(Brand.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            self.toolbarBackground(Brand.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// A method or source note: small, secondary, left aligned.
    func brandNoteStyle() -> some View {
        self.font(.brandNote).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ToolbarContent {
    /// Drops the iOS 26 glass disc behind a toolbar item so a brand chip can stand alone.
    @ToolbarContentBuilder func brandHideGlass() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Sheet close button. Every sheet in the app closes without anything to confirm, so it is an X
/// chip, never "Done", which would imply a choice being saved.
struct BrandDoneButton: View {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.bt(.body, .semibold)).foregroundStyle(.secondary)
                .brandToolbarChip()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// Closes the whole sheet from any page pushed inside it.
private struct BrandCloseKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var brandClose: (() -> Void)? {
        get { self[BrandCloseKey.self] }
        set { self[BrandCloseKey.self] = newValue }
    }
}

/// The custom back chip hides the system back button, which also switches off the edge swipe.
/// This keeps the swipe working whenever there is a page to go back to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// Pushed pages: a back chip on the left in place of the system glass circle, and the sheet's X
/// on the right when the page lives inside a sheet.
private struct BrandCloseButtonModifier: ViewModifier {
    @Environment(\.brandClose) private var close
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.bt(.body, .semibold)).foregroundStyle(.secondary)
                            .brandToolbarChip()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                .brandHideGlass()
                if let close {
                    ToolbarItem(placement: .topBarTrailing) { BrandDoneButton(action: close) }
                        .brandHideGlass()
                }
            }
    }
}

extension View {
    /// Adds the sheet's X to a pushed page, in the corner opposite the back arrow.
    func brandCloseButton() -> some View { modifier(BrandCloseButtonModifier()) }
}

/// A list row that pushes a page: the title and the app's chevron, the same as the card links.
struct BrandLinkRow: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(Color.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.bt(.caption, .bold)).foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Hides the system's thin disclosure chevron where `BrandLinkRow` draws its own.
    @ViewBuilder func brandHideDisclosure() -> some View {
        if #available(iOS 26.0, *) { self.navigationLinkIndicatorVisibility(.hidden) } else { self }
    }
}

/// The app mark: the white p on navy, drawn from the icon's own artwork.
struct BrandMark: View {
    let size: CGFloat
    var body: some View {
        Image("BrandMark").resizable().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
