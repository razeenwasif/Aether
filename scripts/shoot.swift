// Captures an app's frontmost window to a PNG, for checking the UI.
//   swift scripts/shoot.swift Aether build/shots/diffuse.png
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: shoot.swift <app name> <out.png>")
    exit(2)
}
let owner = args[1], out = args[2]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }),
      let id = window[kCGWindowNumber as String] as? Int
else {
    print("no window for \(owner)")
    exit(1)
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-x", "-o", "-l", String(id), out]
try task.run()
task.waitUntilExit()
print("window \(id) -> \(out)")
