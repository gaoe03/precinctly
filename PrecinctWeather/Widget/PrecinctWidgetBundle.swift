import WidgetKit
import SwiftUI

@main
struct PrecinctWidgetBundle: WidgetBundle {
    var body: some Widget {
        PrecinctWidget()       // home screen: systemSmall + systemMedium (color)
        PrecinctLockWidget()   // lock screen: accessory families (monochrome)
    }
}
