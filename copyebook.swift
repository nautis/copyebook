import Foundation
import ScreenCaptureKit
import CoreGraphics
import Vision
import AppKit
import ImageIO

// MARK: - Configuration

struct Config {
    var appName: String? = nil
    var maxPages: Int = 50
    var keyCode: CGKeyCode = 124  // right arrow
    var delay: Double = 1.0
    var outputDir: String = "./copyebook-output"
    var saveScreenshots: Bool = true
    var similarityThreshold: Double = 0.9
}

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1
    func requireValue(for flag: String) -> String {
        guard i + 1 < args.count else {
            print("Error: \(flag) requires a value.")
            printUsage(); exit(1)
        }
        i += 1
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--app":
            config.appName = requireValue(for: "--app")
        case "--pages":
            config.maxPages = Int(requireValue(for: "--pages")) ?? 50
        case "--key":
            let key = requireValue(for: "--key")
            switch key.lowercased() {
            case "space": config.keyCode = 49
            case "left": config.keyCode = 123
            case "right": config.keyCode = 124
            case "down": config.keyCode = 125
            case "up": config.keyCode = 126
            default: config.keyCode = CGKeyCode(key) ?? 124
            }
        case "--delay":
            config.delay = Double(requireValue(for: "--delay")) ?? 1.0
        case "--output":
            config.outputDir = requireValue(for: "--output")
        case "--no-screenshots":
            config.saveScreenshots = false
        case "--similarity":
            config.similarityThreshold = Double(requireValue(for: "--similarity")) ?? 0.9
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
    copyebook — Extract text from any reading app

    Usage: copyebook [options]

    Options:
      --app <name>          Target app name (partial match). Interactive picker if omitted.
      --pages <n>           Max pages to capture (default: 50)
      --key <key>           Page turn key: right, left, up, down, space, or keycode (default: right)
      --delay <seconds>     Wait time after page turn (default: 1.0)
      --output <dir>        Output directory (default: ./copyebook-output)
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

// MARK: - Screenshot Capture

func captureWindow(_ window: SCWindow) async throws -> CGImage {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = Int(window.frame.width) * 2   // Retina
    config.height = Int(window.frame.height) * 2
    config.showsCursor = false
    config.capturesAudio = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

func saveImage(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "copyebook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "copyebook", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG"])
    }
}

// MARK: - OCR

func recognizeText(in image: CGImage) throws -> String {
    var result = ""
    var ocrError: Error?

    let request = VNRecognizeTextRequest { request, error in
        if let error = error {
            ocrError = error
            return
        }
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        result = lines.joined(separator: "\n")
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])

    if let error = ocrError { throw error }
    return result
}

// MARK: - Keystroke Simulation

func sendKeystroke(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .combinedSessionState)

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
        print("Warning: Failed to create key event")
        return
    }

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func activateApp(_ window: SCWindow) {
    guard let app = window.owningApplication,
          let runningApp = NSRunningApplication(processIdentifier: app.processID) else {
        return
    }
    runningApp.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 0.3)
}

// MARK: - Duplicate Detection

func textSimilarity(_ a: String, _ b: String) -> Double {
    guard !a.isEmpty && !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1.0 : 0.0 }

    func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return Set([s]) }
        var set = Set<String>()
        for i in 0..<(chars.count - 1) {
            set.insert(String(chars[i...i+1]))
        }
        return set
    }

    let bigramsA = bigrams(a)
    let bigramsB = bigrams(b)
    let intersection = bigramsA.intersection(bigramsB).count
    let union = bigramsA.union(bigramsB).count
    return union == 0 ? 1.0 : Double(intersection) / Double(union)
}

// MARK: - Output

func setupOutputDir(_ path: String, saveScreenshots: Bool) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    if saveScreenshots {
        try FileManager.default.createDirectory(atPath: "\(path)/screenshots", withIntermediateDirectories: true)
    }
    FileManager.default.createFile(atPath: "\(path)/text.txt", contents: nil)
}

func appendText(_ text: String, pageNumber: Int, to path: String) throws {
    let filePath = "\(path)/text.txt"
    let separator = "\n--- Page \(pageNumber) ---\n\n"
    let content = separator + text + "\n"
    guard let data = content.data(using: .utf8) else { return }

    if let handle = FileHandle(forWritingAtPath: filePath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

// MARK: - Progress

func printProgress(current: Int, total: Int, ocrChars: Int) {
    let width = 30
    let filled = Int(Double(current) / Double(total) * Double(width))
    let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: width - filled)
    print("\rCapturing... [\(bar)] \(current)/\(total) pages (\(ocrChars) chars)", terminator: "")
    fflush(stdout)
}

func printComplete(pages: Int, totalChars: Int, outputDir: String, savedScreenshots: Bool) {
    print("\n")
    print("Done! Captured \(pages) pages (\(totalChars) characters)")
    print("Text saved to: \(outputDir)/text.txt")
    if savedScreenshots {
        print("Screenshots saved to: \(outputDir)/screenshots/")
    }
}

// MARK: - Permissions

func checkAccessibilityPermission() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

// MARK: - Main

@main
struct CopyEbook {
    static func main() async throws {
        print("copyebook v1.0 — macOS eBook Text Extractor")
        print()

        var config = parseArgs()

        // Check accessibility permission (needed for keystroke simulation)
        if !checkAccessibilityPermission() {
            print("Accessibility permission required for page turning.")
            print("Grant it in: System Settings > Privacy & Security > Accessibility")
            print("Then re-run copyebook.")
            exit(1)
        }

        // Enumerate windows
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

        // Select target window
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
        print()

        // Setup output
        do {
            try setupOutputDir(config.outputDir, saveScreenshots: config.saveScreenshots)
        } catch {
            print("Error creating output directory: \(error.localizedDescription)")
            exit(1)
        }

        // Activate the target app
        activateApp(target.scWindow)

        // Brief pause to let app come to front
        try await Task.sleep(for: .milliseconds(500))

        // Capture loop
        var previousText = ""
        var totalChars = 0
        var capturedPages = 0

        for page in 1...config.maxPages {
            // Capture screenshot
            let image: CGImage
            do {
                image = try await captureWindow(target.scWindow)
            } catch {
                print("\nWarning: Failed to capture page \(page): \(error.localizedDescription)")
                continue
            }

            // OCR
            let text: String
            do {
                text = try recognizeText(in: image)
            } catch {
                print("\nWarning: OCR failed on page \(page): \(error.localizedDescription)")
                if config.saveScreenshots {
                    let screenshotPath = "\(config.outputDir)/screenshots/page-\(String(format: "%03d", page)).png"
                    try? saveImage(image, to: screenshotPath)
                }
                continue
            }

            // Duplicate detection
            if !previousText.isEmpty {
                let similarity = textSimilarity(previousText, text)
                if similarity >= config.similarityThreshold {
                    print("\n\nDuplicate page detected (similarity: \(String(format: "%.0f%%", similarity * 100))). Stopping.")
                    break
                }
            }

            // Save outputs
            if config.saveScreenshots {
                let screenshotPath = "\(config.outputDir)/screenshots/page-\(String(format: "%03d", page)).png"
                try? saveImage(image, to: screenshotPath)
            }

            do {
                try appendText(text, pageNumber: page, to: config.outputDir)
            } catch {
                print("\nWarning: Failed to write text for page \(page)")
            }

            previousText = text
            totalChars += text.count
            capturedPages = page

            // Progress
            printProgress(current: page, total: config.maxPages, ocrChars: totalChars)

            // Turn page (skip on last page)
            if page < config.maxPages {
                activateApp(target.scWindow)
                sendKeystroke(config.keyCode)
                try await Task.sleep(for: .milliseconds(Int(config.delay * 1000)))
            }
        }

        printComplete(
            pages: capturedPages,
            totalChars: totalChars,
            outputDir: config.outputDir,
            savedScreenshots: config.saveScreenshots
        )
    }
}
