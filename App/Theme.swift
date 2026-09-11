import SwiftUI

/// Only a dark palette exists; the app declares `UIUserInterfaceStyle = Dark`.
enum Theme {
    static let accent = Color(red: 0.44, green: 0.62, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)
    static let success = Color(red: 0.36, green: 0.80, blue: 0.55)

    static let background = Color(red: 0.066, green: 0.071, blue: 0.078)   // #111214
    static let card = Color(red: 0.106, green: 0.114, blue: 0.125)         // #1B1D20
    static let hairline = Color.white.opacity(0.09)
    static let primaryText = Color(red: 0.914, green: 0.906, blue: 0.890)  // #E9E7E3
    static let secondaryText = Color(red: 0.545, green: 0.561, blue: 0.588) // #8B8F96

    /// Mirrors the reader stylesheet so the native chrome matches the page.
    static let readerBackground = Color(red: 0.066, green: 0.071, blue: 0.078)
}
