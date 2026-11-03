// Prints the CGWindowID of an app's main window, for `screencapture -l`. Usage: swift tools/windowid.swift "App Name"
// (System Events window ids do not work with screencapture -l; these do.)
import CoreGraphics
let owner = CommandLine.arguments.dropFirst().first ?? ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerName as String] as? String) == owner && (window[kCGWindowLayer as String] as? Int) == 0 {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    if let height = bounds["Height"] as? Double, height < 100 { continue } // skip menu-bar strips
    print(window[kCGWindowNumber as String] ?? "")
    break
}
