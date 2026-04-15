import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision
import AppKit

// MARK: - Configuration

struct Config {
    var appName: String? = nil
    var maxPages: Int = 50
    var keyCode: CGKeyCode = 124  // right arrow
    var delay: Double = 1.0
    var outputDir: String = "./bookmuncher-output"
    var saveScreenshots: Bool = true
    var similarityThreshold: Double = 0.9
}

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--app":
            i += 1; config.appName = args[i]
        case "--pages":
            i += 1; config.maxPages = Int(args[i]) ?? 50
        case "--key":
            i += 1
            switch args[i].lowercased() {
            case "space": config.keyCode = 49
            case "left": config.keyCode = 123
            case "right": config.keyCode = 124
            case "down": config.keyCode = 125
            case "up": config.keyCode = 126
            default: config.keyCode = CGKeyCode(args[i]) ?? 124
            }
        case "--delay":
            i += 1; config.delay = Double(args[i]) ?? 1.0
        case "--output":
            i += 1; config.outputDir = args[i]
        case "--no-screenshots":
            config.saveScreenshots = false
        case "--similarity":
            i += 1; config.similarityThreshold = Double(args[i]) ?? 0.9
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            print("Unknown option: \(args[i])")
            printUsage(); exit(1)
        }
        i += 1
    }
    return config
}

func printUsage() {
    print("""
    BookMuncher — Extract text from any reading app

    Usage: bookmuncher [options]

    Options:
      --app <name>          Target app name (partial match). Interactive picker if omitted.
      --pages <n>           Max pages to capture (default: 50)
      --key <key>           Page turn key: right, left, up, down, space, or keycode (default: right)
      --delay <seconds>     Wait time after page turn (default: 1.0)
      --output <dir>        Output directory (default: ./bookmuncher-output)
      --no-screenshots      Don't save screenshot PNGs
      --similarity <0-1>    Duplicate detection threshold (default: 0.9)
      -h, --help            Show this help
    """)
}

// MARK: - Window Enumeration

struct WindowInfo {
    let windowID: CGWindowID
    let scWindow: SCWindow
    let appName: String
    let title: String
}

func enumerateWindows() async throws -> [WindowInfo] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    return content.windows.compactMap { window in
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        guard !appName.isEmpty, window.frame.width > 200, window.frame.height > 200 else {
            return nil
        }
        return WindowInfo(
            windowID: window.windowID,
            scWindow: window,
            appName: appName,
            title: title
        )
    }
}

func pickWindow(windows: [WindowInfo]) -> WindowInfo? {
    print("\nAvailable windows:")
    for (i, w) in windows.enumerated() {
        let title = w.title.isEmpty ? "(untitled)" : w.title
        print("  \(i + 1). \(w.appName) — \"\(title)\"")
    }
    print()
    print("Select window [1-\(windows.count)]: ", terminator: "")
    guard let line = readLine(), let idx = Int(line), idx >= 1, idx <= windows.count else {
        print("Invalid selection.")
        return nil
    }
    return windows[idx - 1]
}

func findWindow(appName: String, windows: [WindowInfo]) -> WindowInfo? {
    let lower = appName.lowercased()
    return windows.first { $0.appName.lowercased().contains(lower) }
}

func interactiveConfig(_ config: inout Config) {
    print("Pages to capture (default \(config.maxPages)): ", terminator: "")
    if let line = readLine(), let n = Int(line), n > 0 {
        config.maxPages = n
    }

    print("Page turn key (default: right arrow): ", terminator: "")
    if let line = readLine(), !line.isEmpty {
        switch line.lowercased() {
        case "space": config.keyCode = 49
        case "left": config.keyCode = 123
        case "right": config.keyCode = 124
        case "down": config.keyCode = 125
        case "up": config.keyCode = 126
        default: break
        }
    }

    print("Output directory (default: \(config.outputDir)): ", terminator: "")
    if let line = readLine(), !line.isEmpty {
        config.outputDir = line
    }
}

// MARK: - Main

@main
struct BookMuncher {
    static func main() async throws {
        var config = parseArgs()

        let windows: [WindowInfo]
        do {
            windows = try await enumerateWindows()
        } catch {
            print("Error: Could not enumerate windows.")
            print("Grant Screen Recording permission in:")
            print("  System Settings > Privacy & Security > Screen Recording")
            print("\nDetails: \(error.localizedDescription)")
            exit(1)
        }

        guard !windows.isEmpty else {
            print("No application windows found.")
            exit(1)
        }

        let target: WindowInfo
        if let appName = config.appName {
            guard let found = findWindow(appName: appName, windows: windows) else {
                print("No window found matching \"\(appName)\". Available:")
                for w in windows { print("  - \(w.appName)") }
                exit(1)
            }
            target = found
        } else {
            guard let picked = pickWindow(windows: windows) else { exit(1) }
            target = picked
            interactiveConfig(&config)
        }

        print("\nTarget: \(target.appName) — \"\(target.title)\"")
        print("Pages: \(config.maxPages), Delay: \(config.delay)s")
        print("Output: \(config.outputDir)")
    }
}
