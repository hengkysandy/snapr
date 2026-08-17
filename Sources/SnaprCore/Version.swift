import Foundation

public enum SnaprVersion {
    /// The version lives in three places: here, `project.yml` (twice), and the
    /// DMG filename that `./app dmg` derives from `project.yml`. A test asserts
    /// this string matches the built bundle, so the suite fails when they drift
    /// rather than the DMG quietly disagreeing with the About box.
    public static let marketing = "0.1.0"
    public static let build = "1"

    public static var displayString: String { "Snapr \(marketing) (\(build))" }
}
