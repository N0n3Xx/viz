// Minimalist terminal audio visualizer — captures desktop audio via ScreenCaptureKit
// No external dependencies. macOS 13+.

import Accelerate
import AVFoundation
import Foundation
import ScreenCaptureKit

// ── constants ───────────────────────────────────────────────────────────────
let sampleRate: Double = 48000
let fftSize: Int = 2048
let minFreq: Float = 30
let maxFreq: Float = 16000
let floorDB: Float = -60
let ceilDB: Float = -5

// ── color themes ────────────────────────────────────────────────────────────
// Each theme is 4 color stops (r,g,b) interpolated bottom→top, plus a name.
struct ColorStop { let r: Float; let g: Float; let b: Float }
struct Theme {
    let name: String
    let stops: [ColorStop]  // exactly 4 stops: bottom → top
}

let themes: [Theme] = [
    Theme(name: "ocean", stops: [
        ColorStop(r: 20, g: 40, b: 120),
        ColorStop(r: 30, g: 150, b: 180),
        ColorStop(r: 60, g: 210, b: 130),
        ColorStop(r: 230, g: 250, b: 255),
    ]),
    Theme(name: "fire", stops: [
        ColorStop(r: 80, g: 10, b: 5),
        ColorStop(r: 200, g: 50, b: 10),
        ColorStop(r: 250, g: 160, b: 20),
        ColorStop(r: 255, g: 250, b: 180),
    ]),
    Theme(name: "purple", stops: [
        ColorStop(r: 40, g: 10, b: 80),
        ColorStop(r: 120, g: 30, b: 160),
        ColorStop(r: 200, g: 80, b: 200),
        ColorStop(r: 255, g: 200, b: 255),
    ]),
    Theme(name: "matrix", stops: [
        ColorStop(r: 0, g: 30, b: 0),
        ColorStop(r: 0, g: 100, b: 10),
        ColorStop(r: 20, g: 200, b: 40),
        ColorStop(r: 180, g: 255, b: 180),
    ]),
    Theme(name: "sunset", stops: [
        ColorStop(r: 40, g: 10, b: 60),
        ColorStop(r: 160, g: 30, b: 60),
        ColorStop(r: 240, g: 100, b: 30),
        ColorStop(r: 255, g: 220, b: 100),
    ]),
    Theme(name: "ice", stops: [
        ColorStop(r: 10, g: 20, b: 60),
        ColorStop(r: 30, g: 80, b: 160),
        ColorStop(r: 100, g: 180, b: 230),
        ColorStop(r: 220, g: 240, b: 255),
    ]),
    Theme(name: "mono", stops: [
        ColorStop(r: 40, g: 40, b: 40),
        ColorStop(r: 100, g: 100, b: 100),
        ColorStop(r: 180, g: 180, b: 180),
        ColorStop(r: 250, g: 250, b: 250),
    ]),
    Theme(name: "candy", stops: [
        ColorStop(r: 60, g: 20, b: 100),
        ColorStop(r: 220, g: 50, b: 120),
        ColorStop(r: 80, g: 200, b: 220),
        ColorStop(r: 255, g: 240, b: 100),
    ]),
]

// ── adjustable parameters ───────────────────────────────────────────────────
let settingsLock = NSLock()

var gain: Float = 2.0
let gainMin: Float = 0.4
let gainMax: Float = 8.0
let gainStep: Float = 0.2

var barWidth: Int = 2
let barWidthMin = 1
let barWidthMax = 12

var barGap: Int = 1
let barGapMin = 0
let barGapMax = 6

var smoothing: Float = 0.55
let smoothingMin: Float = 0.0
let smoothingMax: Float = 0.95
let smoothingStep: Float = 0.05

var frameInterval: Double = 0.0
let frameIntervalMin: Double = 0.0
let frameIntervalMax: Double = 0.15
let frameIntervalStep: Double = 0.01

var peakFallSpeed: Float = 0.012
let peakFallMin: Float = 0.003
let peakFallMax: Float = 0.06
let peakFallStep: Float = 0.003

var themeIndex: Int = 0

// ── state ───────────────────────────────────────────────────────────────────
var prevBands: [Float] = []
var peakBands: [Float] = []
var fftSetup: vDSP_DFT_Setup?
var lastFrameTime: Double = 0
var activeParam: Int = 0
let paramCount = 7
var settingsDirty = false
var lastSaveTime: Double = 0
let saveDebounce: Double = 1.0

// ── settings persistence ────────────────────────────────────────────────────
let settingsPath: String = {
    let dir = NSString(string: "~/.config/viz").expandingTildeInPath
    return dir + "/settings.json"
}()

func saveSettings() {
    let dir = NSString(string: settingsPath).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let dict: [String: Any] = [
        "gain": gain,
        "barWidth": barWidth,
        "barGap": barGap,
        "smoothing": smoothing,
        "frameInterval": frameInterval,
        "peakFallSpeed": peakFallSpeed,
        "theme": themes[themeIndex].name,
    ]

    if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: settingsPath))
    }
}

func loadSettings() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

    if let v = dict["gain"] as? Float { gain = max(gainMin, min(v, gainMax)) }
    if let v = dict["barWidth"] as? Int { barWidth = max(barWidthMin, min(v, barWidthMax)) }
    if let v = dict["barGap"] as? Int { barGap = max(barGapMin, min(v, barGapMax)) }
    if let v = dict["smoothing"] as? Float { smoothing = max(smoothingMin, min(v, smoothingMax)) }
    if let v = dict["frameInterval"] as? Double { frameInterval = max(frameIntervalMin, min(v, frameIntervalMax)) }
    if let v = dict["peakFallSpeed"] as? Float { peakFallSpeed = max(peakFallMin, min(v, peakFallMax)) }
    if let v = dict["theme"] as? String {
        if let idx = themes.firstIndex(where: { $0.name == v }) { themeIndex = idx }
    }
}

func markDirty() { settingsDirty = true }

func maybeSave() {
    guard settingsDirty else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastSaveTime >= saveDebounce {
        saveSettings()
        settingsDirty = false
        lastSaveTime = now
    }
}

// ── atomic frame output ─────────────────────────────────────────────────────
let outputFd = STDOUT_FILENO

func writeFrame(_ str: String) {
    let data = Array(str.utf8)
    data.withUnsafeBufferPointer { buf in
        var written = 0
        while written < buf.count {
            let n = Darwin.write(outputFd, buf.baseAddress! + written, buf.count - written)
            if n <= 0 { break }
            written += n
        }
    }
}

// ── color interpolation ────────────────────────────────────────────────────
func lerpStop(_ a: ColorStop, _ b: ColorStop, _ t: Float) -> (Int, Int, Int) {
    let r = Int(a.r + (b.r - a.r) * t)
    let g = Int(a.g + (b.g - a.g) * t)
    let b_ = Int(a.b + (b.b - a.b) * t)
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b_)))
}

func colorForHeight(_ fraction: Float, theme: Theme) -> String {
    // fraction 0..1, interpolate across 4 stops
    let f = max(0, min(1, fraction))
    let segment = f * 3.0  // 0..3
    let idx = min(Int(segment), 2)
    let t = segment - Float(idx)
    let (r, g, b) = lerpStop(theme.stops[idx], theme.stops[idx + 1], t)
    return "\u{1B}[38;2;\(r);\(g);\(b)m"
}

func dimColorForHeight(_ fraction: Float, theme: Theme) -> String {
    let f = max(0, min(1, fraction))
    let segment = f * 3.0
    let idx = min(Int(segment), 2)
    let t = segment - Float(idx)
    let (r, g, b) = lerpStop(theme.stops[idx], theme.stops[idx + 1], t)
    // dim to ~20% brightness
    return "\u{1B}[38;2;\(r / 5);\(g / 5);\(b / 5)m"
}

let resetColor = "\u{1B}[0m"
let dimColor = "\u{1B}[38;2;50;55;60m"
let labelColor = "\u{1B}[38;2;80;85;90m"
let valueColor = "\u{1B}[38;2;120;190;230m"
let activeLabel = "\u{1B}[38;2;220;230;240m"
let activeValue = "\u{1B}[38;2;120;220;180m"
let barFillColor = "\u{1B}[38;2;80;160;200m"
let barEmptyColor = "\u{1B}[38;2;35;38;42m"

// ── bar characters ──────────────────────────────────────────────────────────
let barChars: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
let peakChar: Character = "━"

// ── terminal helpers ────────────────────────────────────────────────────────
var origTermios = termios()

func termSize() -> (cols: Int, rows: Int) {
    var w = winsize()
    _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w)
    return (Int(w.ws_col), Int(w.ws_row))
}

func hideCursor() { writeFrame("\u{1B}[?25l") }
func showCursor() { writeFrame("\u{1B}[?25h\u{1B}[0m\n") }
func clearScreen() { writeFrame("\u{1B}[2J") }

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &origTermios)
    var raw = origTermios
    raw.c_lflag &= ~UInt(ECHO | ICANON)
    raw.c_cc.16 = 1  // VMIN
    raw.c_cc.17 = 0  // VTIME
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

func disableRawMode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &origTermios)
}

// ── keyboard input ──────────────────────────────────────────────────────────
func startKeyboardListener() {
    enableRawMode()
    DispatchQueue.global(qos: .userInitiated).async {
        var buf = [UInt8](repeating: 0, count: 3)
        while true {
            let n = read(STDIN_FILENO, &buf, 3)
            if n == 1 {
                switch buf[0] {
                case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                    cleanup(); exit(0)
                case UInt8(ascii: "\t"), UInt8(ascii: " "):
                    settingsLock.lock()
                    activeParam = (activeParam + 1) % paramCount
                    settingsLock.unlock()
                case 0x7F, UInt8(ascii: "`"):
                    settingsLock.lock()
                    activeParam = (activeParam - 1 + paramCount) % paramCount
                    settingsLock.unlock()
                default: break
                }
            } else if n == 3 && buf[0] == 0x1B && buf[1] == 0x5B {
                settingsLock.lock()
                let param = activeParam
                if buf[2] == 0x41 { // up arrow
                    switch param {
                    case 0: gain = min(gain + gainStep, gainMax)
                    case 1: barWidth = min(barWidth + 1, barWidthMax)
                    case 2: barGap = min(barGap + 1, barGapMax)
                    case 3: smoothing = min(smoothing + smoothingStep, smoothingMax)
                    case 4: frameInterval = min(frameInterval + frameIntervalStep, frameIntervalMax)
                    case 5: peakFallSpeed = max(peakFallSpeed - peakFallStep, peakFallMin)
                    case 6: themeIndex = (themeIndex + 1) % themes.count
                    default: break
                    }
                    markDirty()
                } else if buf[2] == 0x42 { // down arrow
                    switch param {
                    case 0: gain = max(gain - gainStep, gainMin)
                    case 1: barWidth = max(barWidth - 1, barWidthMin)
                    case 2: barGap = max(barGap - 1, barGapMin)
                    case 3: smoothing = max(smoothing - smoothingStep, smoothingMin)
                    case 4: frameInterval = max(frameInterval - frameIntervalStep, frameIntervalMin)
                    case 5: peakFallSpeed = min(peakFallSpeed + peakFallStep, peakFallMax)
                    case 6: themeIndex = (themeIndex - 1 + themes.count) % themes.count
                    default: break
                    }
                    markDirty()
                } else if buf[2] == 0x43 { // right arrow
                    activeParam = (activeParam + 1) % paramCount
                } else if buf[2] == 0x44 { // left arrow
                    activeParam = (activeParam - 1 + paramCount) % paramCount
                }
                settingsLock.unlock()
            }
        }
    }
}

// ── helpers ─────────────────────────────────────────────────────────────────
func miniBar(_ fraction: Float, width: Int, fill: String, empty: String) -> String {
    let filled = Int(fraction * Float(width))
    let rest = width - filled
    return fill + String(repeating: "━", count: filled) + empty + String(repeating: "╌", count: rest)
}

func paramDisplay(name: String, value: String, fraction: Float, barW: Int, isActive: Bool) -> String {
    let lc = isActive ? activeLabel : labelColor
    let vc = isActive ? activeValue : valueColor
    let fc = isActive ? activeValue : barFillColor
    let ec = barEmptyColor
    let indicator = isActive ? "\(activeLabel)▸ " : "  "
    return "\(indicator)\(lc)\(name) \(vc)\(value) \(miniBar(fraction, width: barW, fill: fc, empty: ec))\(resetColor)"
}

// theme display: show name + color swatch
func themeDisplay(theme: Theme, isActive: Bool) -> String {
    let lc = isActive ? activeLabel : labelColor
    let vc = isActive ? activeValue : valueColor
    let indicator = isActive ? "\(activeLabel)▸ " : "  "

    // render a small gradient swatch
    var swatch = ""
    let swatchWidth = 8
    for i in 0..<swatchWidth {
        let f = Float(i) / Float(swatchWidth - 1)
        let color = colorForHeight(f, theme: theme)
        swatch += "\(color)█"
    }

    return "\(indicator)\(lc)theme \(vc)\(theme.name) \(swatch)\(resetColor)"
}

// ── FFT + rendering ────────────────────────────────────────────────────────
func logBandEdges(nBands: Int, nFFT: Int, sr: Double) -> [Int] {
    var edges = [Int]()
    let logMin = log10(minFreq)
    let logMax = log10(maxFreq)
    for i in 0...nBands {
        let freq = pow(10, logMin + (logMax - logMin) * Float(i) / Float(nBands))
        let bin = Int(freq * Float(nFFT) / Float(sr))
        edges.append(min(bin, nFFT / 2))
    }
    return edges
}

func processAudio(_ samples: [Float]) {
    // frame rate limiting
    let now = CFAbsoluteTimeGetCurrent()
    settingsLock.lock()
    let interval = frameInterval
    settingsLock.unlock()
    if interval > 0 && (now - lastFrameTime) < interval { return }
    lastFrameTime = now

    settingsLock.lock()
    let currentGain = gain
    let currentBarWidth = barWidth
    let currentBarGap = barGap
    let currentSmoothing = smoothing
    let currentPeakFall = peakFallSpeed
    let currentFrameInterval = frameInterval
    let currentActiveParam = activeParam
    let currentTheme = themes[themeIndex]
    settingsLock.unlock()

    let (cols, rows) = termSize()
    let bandStride = currentBarWidth + currentBarGap
    let nBands = max(1, cols / max(1, bandStride))
    let n = min(samples.count, fftSize)

    if fftSetup == nil {
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }
    guard let setup = fftSetup else { return }

    // apply Hann window
    var windowed = [Float](repeating: 0, count: fftSize)
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    for i in 0..<n { windowed[i] = samples[i] * window[i] }

    // split complex for DFT
    let halfN = fftSize / 2
    var inputReal = [Float](repeating: 0, count: halfN)
    var inputImag = [Float](repeating: 0, count: halfN)
    for i in 0..<halfN {
        inputReal[i] = windowed[2 * i]
        inputImag[i] = windowed[2 * i + 1]
    }

    var outputReal = [Float](repeating: 0, count: halfN)
    var outputImag = [Float](repeating: 0, count: halfN)
    vDSP_DFT_Execute(setup, &inputReal, &inputImag, &outputReal, &outputImag)

    // magnitude in dB
    var magnitudes = [Float](repeating: 0, count: halfN)
    for i in 0..<halfN {
        let mag = sqrt(outputReal[i] * outputReal[i] + outputImag[i] * outputImag[i])
        magnitudes[i] = 20 * log10(max(mag / Float(fftSize), 1e-10))
    }

    // bin into log bands
    let edges = logBandEdges(nBands: nBands, nFFT: fftSize, sr: sampleRate)
    var bands = [Float](repeating: floorDB, count: nBands)
    for i in 0..<nBands {
        let lo = edges[i]
        var hi = edges[i + 1]
        if hi <= lo { hi = lo + 1 }
        if lo < halfN {
            let slice = magnitudes[lo..<min(hi, halfN)]
            bands[i] = slice.max() ?? floorDB
        }
    }

    // normalize, smooth
    if prevBands.count != nBands {
        prevBands = [Float](repeating: 0, count: nBands)
        peakBands = [Float](repeating: 0, count: nBands)
    }

    var norm = [Float](repeating: 0, count: nBands)
    for i in 0..<nBands {
        let v = ((bands[i] * currentGain) - floorDB) / (ceilDB - floorDB)
        let clamped = max(0, min(1, v))
        norm[i] = currentSmoothing * prevBands[i] + (1 - currentSmoothing) * clamped
    }
    prevBands = norm

    // falling peaks
    for i in 0..<nBands {
        if norm[i] > peakBands[i] {
            peakBands[i] = norm[i]
        } else {
            peakBands[i] = max(peakBands[i] - currentPeakFall, 0)
        }
    }

    // ── render ──────────────────────────────────────────────────────────────
    let statusHeight = 2
    let height = rows - 1 - statusHeight
    if height < 2 { return }
    let nChars = barChars.count - 1

    var output = "\u{1B}[H"
    output.reserveCapacity(cols * (height + statusHeight) * 16)

    // peak color from theme top stop
    let peakStop = currentTheme.stops[3]
    let peakColor = "\u{1B}[38;2;\(Int(peakStop.r));\(Int(peakStop.g));\(Int(peakStop.b))m"

    for row in stride(from: height, through: 1, by: -1) {
        let threshold = Float(row) / Float(height)
        let heightFrac = 1.0 - Float(row - 1) / Float(height)
        let color = colorForHeight(heightFrac, theme: currentTheme)
        let gapColor = currentBarGap > 0 ? dimColorForHeight(heightFrac, theme: currentTheme) : ""
        var col = 0

        output.append(color)
        for i in 0..<nBands {
            let val = norm[i]
            let peak = peakBands[i]

            let peakRow = Float(height) * peak
            let rowTop = Float(row)
            let rowBot = Float(row - 1)
            let isPeak = peak > 0.02 && peakRow >= rowBot && peakRow < rowTop && val < threshold

            for _ in 0..<currentBarWidth {
                if isPeak {
                    output.append(peakColor)
                    output.append(peakChar)
                    output.append(color)
                } else if val >= threshold {
                    output.append(barChars[nChars])
                } else if val >= threshold - (1.0 / Float(height)) {
                    let frac = (val - (threshold - 1.0 / Float(height))) * Float(height)
                    let idx = Int(frac * Float(nChars))
                    output.append(barChars[max(0, min(idx, nChars))])
                } else {
                    output.append(" ")
                }
                col += 1
            }

            if currentBarGap > 0 {
                output.append(gapColor)
                for _ in 0..<currentBarGap {
                    output.append(" ")
                    col += 1
                }
                output.append(color)
            }
        }
        while col < cols { output.append(" "); col += 1 }
        output.append(resetColor)
        if row > 1 { output.append("\n") }
    }

    // ── status bar ──────────────────────────────────────────────────────────
    let barW = 8

    let gainFrac = (currentGain - gainMin) / (gainMax - gainMin)
    let widthFrac = Float(currentBarWidth - barWidthMin) / Float(max(1, barWidthMax - barWidthMin))
    let gapFrac = Float(currentBarGap - barGapMin) / Float(max(1, barGapMax - barGapMin))
    let smoothFrac = (currentSmoothing - smoothingMin) / (smoothingMax - smoothingMin)
    let fiFrac = Float(currentFrameInterval - frameIntervalMin) / Float(frameIntervalMax - frameIntervalMin)
    let peakFrac = 1.0 - (currentPeakFall - peakFallMin) / (peakFallMax - peakFallMin)

    let fps = currentFrameInterval > 0 ? String(format: "%.0f", 1.0 / currentFrameInterval) : "max"

    let params: [String] = [
        paramDisplay(name: "gain", value: String(format: "%3.0f%%", gainFrac * 100), fraction: gainFrac, barW: barW, isActive: currentActiveParam == 0),
        paramDisplay(name: "width", value: "\(currentBarWidth)", fraction: widthFrac, barW: barW, isActive: currentActiveParam == 1),
        paramDisplay(name: "gap", value: "\(currentBarGap)", fraction: gapFrac, barW: barW, isActive: currentActiveParam == 2),
        paramDisplay(name: "smooth", value: String(format: "%.0f%%", smoothFrac * 100), fraction: smoothFrac, barW: barW, isActive: currentActiveParam == 3),
        paramDisplay(name: "rate", value: "\(fps)fps", fraction: fiFrac, barW: barW, isActive: currentActiveParam == 4),
        paramDisplay(name: "peaks", value: String(format: "%.0f%%", peakFrac * 100), fraction: peakFrac, barW: barW, isActive: currentActiveParam == 5),
        themeDisplay(theme: currentTheme, isActive: currentActiveParam == 6),
    ]

    let separator = "  \(dimColor)│\(resetColor)  "
    let statusLine = params.joined(separator: separator)
    let helpLine = "\(dimColor)  ←→ select   ↑↓ adjust   q quit\(resetColor)"

    output.append("\n" + statusLine + String(repeating: " ", count: max(0, cols - 160)))
    output.append("\n" + helpLine + String(repeating: " ", count: max(0, cols - 42)))

    writeFrame(output)

    settingsLock.lock()
    maybeSave()
    settingsLock.unlock()
}

// ── ScreenCaptureKit audio capture ──────────────────────────────────────────
class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            print("No display found")
            exit(1)
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = false

        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }
        let floatCount = length / MemoryLayout<Float>.size
        let floatPtr = data.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: floatCount))
        }

        processAudio(floatPtr)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cleanup()
        print("\nStream stopped: \(error.localizedDescription)")
        exit(1)
    }
}

// ── lifecycle ───────────────────────────────────────────────────────────────
func cleanup() {
    settingsLock.lock()
    if settingsDirty { saveSettings() }
    settingsLock.unlock()
    disableRawMode()
    showCursor()
}

signal(SIGINT) { _ in cleanup(); exit(0) }
signal(SIGTERM) { _ in cleanup(); exit(0) }

loadSettings()
hideCursor()
clearScreen()
startKeyboardListener()

let capture = AudioCapture()

Task {
    do {
        try await capture.start()
    } catch {
        cleanup()
        print("Failed to start capture: \(error.localizedDescription)")
        print("Grant Screen Recording permission in System Settings → Privacy & Security.")
        exit(1)
    }
}

RunLoop.main.run()
