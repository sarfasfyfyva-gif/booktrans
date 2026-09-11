import Foundation
import BookTransCore
import SwiftUI

/// Bridges the app's stored preferences into the reader page's configuration, so
/// the WebView and the native chrome stay in step.
enum ReaderTheme {
    static func configuration(
        settings: AppSettings, showTranslation: Bool
    ) -> ReaderHTMLBuilder.Configuration {
        ReaderHTMLBuilder.Configuration(
            showTranslation: showTranslation,
            fontSize: settings.readerFontSize,
            lineHeight: settings.readerLineHeight,
            margin: settings.readerMargin)
    }

    static let background = Theme.readerBackground
    static let textColor = Theme.primaryText
}
