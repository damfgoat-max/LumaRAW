import Foundation

/// Single source of truth for the app's identity strings.
/// To rename the app: change `appName` here (display strings + Photos album
/// follow automatically) and PRODUCT_NAME / target name in project.yml.
enum AppConstants {
    static let appName = "LumaRAW"
    static let albumName = appName
    static let lutDirectoryName = "LUTs"
}
