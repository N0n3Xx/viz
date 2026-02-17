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
struct ColorStop { let r: Float; let g: Float; let b: Float }
struct Theme {
    let name: String
    let stops: [ColorStop]
}

let themes: [Theme] = [
    Theme(name: "ocean", stops: [
        ColorStop(r: 20, g: 40, b: 120), ColorStop(r: 30, g: 150, b: 180),
        ColorStop(r: 60, g: 210, b: 130), ColorStop(r: 230, g: 250, b: 255),
    ]),
    Theme(name: "fire", stops: [
        ColorStop(r: 80, g: 10, b: 5), ColorStop(r: 200, g: 50, b: 10),
        ColorStop(r: 250, g: 160, b: 20), ColorStop(r: 255, g: 250, b: 180),
    ]),
    Theme(name: "purple", stops: [
        ColorStop(r: 40, g: 10, b: 80), ColorStop(r: 120, g: 30, b: 160),
        ColorStop(r: 200, g: 80, b: 200), ColorStop(r: 255, g: 200, b: 255),
    ]),
    Theme(name: "matrix", stops: [
        ColorStop(r: 0, g: 30, b: 0), ColorStop(r: 0, g: 100, b: 10),
        ColorStop(r: 20, g: 200, b: 40), ColorStop(r: 180, g: 255, b: 180),
    ]),
    Theme(name: "sunset", stops: [
        ColorStop(r: 40, g: 10, b: 60), ColorStop(r: 160, g: 30, b: 60),
        ColorStop(r: 240, g: 100, b: 30), ColorStop(r: 255, g: 220, b: 100),
    ]),
    Theme(name: "ice", stops: [
        ColorStop(r: 10, g: 20, b: 60), ColorStop(r: 30, g: 80, b: 160),
        ColorStop(r: 100, g: 180, b: 230), ColorStop(r: 220, g: 240, b: 255),
    ]),
    Theme(name: "mono", stops: [
        ColorStop(r: 40, g: 40, b: 40), ColorStop(r: 100, g: 100, b: 100),
        ColorStop(r: 180, g: 180, b: 180), ColorStop(r: 250, g: 250, b: 250),
    ]),
    Theme(name: "candy", stops: [
        ColorStop(r: 60, g: 20, b: 100), ColorStop(r: 220, g: 50, b: 120),
        ColorStop(r: 80, g: 200, b: 220), ColorStop(r: 255, g: 240, b: 100),
    ]),
    Theme(name: "aurora", stops: [
        ColorStop(r: 10, g: 10, b: 40), ColorStop(r: 20, g: 120, b: 80),
        ColorStop(r: 100, g: 60, b: 180), ColorStop(r: 200, g: 220, b: 255),
    ]),
    Theme(name: "blood", stops: [
        ColorStop(r: 30, g: 0, b: 0), ColorStop(r: 120, g: 10, b: 10),
        ColorStop(r: 200, g: 30, b: 30), ColorStop(r: 255, g: 100, b: 80),
    ]),
]

// ── adjustable parameters ───────────────────────────────────────────────────
let settingsLock = NSLock()

var gain: Float = 2.0
let gainMin: Float = 0.4; let gainMax: Float = 8.0; let gainStep: Float = 0.2

var barWidth: Int = 2
let barWidthMin = 1; let barWidthMax = 12

var barGap: Int = 1
let barGapMin = 0; let barGapMax = 6

var smoothing: Float = 0.55
let smoothingMin: Float = 0.0; let smoothingMax: Float = 0.95; let smoothingStep: Float = 0.05

var frameInterval: Double = 0.0
let frameIntervalMin: Double = 0.0; let frameIntervalMax: Double = 0.15; let frameIntervalStep: Double = 0.01

var peakFallSpeed: Float = 0.012
let peakFallMin: Float = 0.003; let peakFallMax: Float = 0.06; let peakFallStep: Float = 0.003

var themeIndex: Int = 0

// ── visual effects ──────────────────────────────────────────────────────────
var fxMirror: Bool = false       // mirror bars from center
var fxFlip: Bool = false         // bars hang from top
var fxShadow: Bool = false       // trailing shadow/afterglow
var fxGlow: Bool = true          // color bleed to neighboring columns
var fxPeaks: Bool = true         // falling peak indicators

var shadowTrail: [[Float]] = []  // ring buffer of past frames for shadow
let shadowDepth = 16
var shadowIndex = 0

// ── submenu system ──────────────────────────────────────────────────────────
// tabs: audio | bars | motion | style
struct MenuTab {
    let name: String
    let paramCount: Int
}

let menuTabs: [MenuTab] = [
    MenuTab(name: "audio", paramCount: 1),   // gain
    MenuTab(name: "bars", paramCount: 2),     // width, gap
    MenuTab(name: "motion", paramCount: 3),   // smooth, rate, peaks
    MenuTab(name: "style", paramCount: 7),    // theme, mirror, flip, shadow, glow, peak-dots
]

var activeTab: Int = 0
var activeItem: Int = 0  // item within current tab

// ── state ───────────────────────────────────────────────────────────────────
var prevBands: [Float] = []
var peakBands: [Float] = []
var fftSetup: vDSP_DFT_Setup?
var lastFrameTime: Double = 0
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
        "gain": gain, "barWidth": barWidth, "barGap": barGap,
        "smoothing": smoothing, "frameInterval": frameInterval,
        "peakFallSpeed": peakFallSpeed, "theme": themes[themeIndex].name,
        "fxMirror": fxMirror, "fxFlip": fxFlip, "fxShadow": fxShadow,
        "fxGlow": fxGlow, "fxPeaks": fxPeaks,
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
    if let v = dict["fxMirror"] as? Bool { fxMirror = v }
    if let v = dict["fxFlip"] as? Bool { fxFlip = v }
    if let v = dict["fxShadow"] as? Bool { fxShadow = v }
    if let v = dict["fxGlow"] as? Bool { fxGlow = v }
    if let v = dict["fxPeaks"] as? Bool { fxPeaks = v }
}

func markDirty() { settingsDirty = true }

func maybeSave() {
    guard settingsDirty else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastSaveTime >= saveDebounce {
        saveSettings(); settingsDirty = false; lastSaveTime = now
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

func rgbForHeight(_ fraction: Float, theme: Theme) -> (Int, Int, Int) {
    let f = max(0, min(1, fraction))
    let segment = f * 3.0
    let idx = min(Int(segment), 2)
    let t = segment - Float(idx)
    return lerpStop(theme.stops[idx], theme.stops[idx + 1], t)
}

func colorForHeight(_ fraction: Float, theme: Theme) -> String {
    let (r, g, b) = rgbForHeight(fraction, theme: theme)
    return "\u{1B}[38;2;\(r);\(g);\(b)m"
}

func dimColorForHeight(_ fraction: Float, theme: Theme) -> String {
    let (r, g, b) = rgbForHeight(fraction, theme: theme)
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
let onColor = "\u{1B}[38;2;100;220;140m"
let offColor = "\u{1B}[38;2;70;50;50m"

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
    raw.c_cc.16 = 1; raw.c_cc.17 = 0
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

func disableRawMode() { tcsetattr(STDIN_FILENO, TCSAFLUSH, &origTermios) }

// ── keyboard input ──────────────────────────────────────────────────────────
func handleUp() {
    let tab = activeTab; let item = activeItem
    switch tab {
    case 0: // audio
        gain = min(gain + gainStep, gainMax)
    case 1: // bars
        switch item {
        case 0: barWidth = min(barWidth + 1, barWidthMax)
        case 1: barGap = min(barGap + 1, barGapMax)
        default: break
        }
    case 2: // motion
        switch item {
        case 0: smoothing = min(smoothing + smoothingStep, smoothingMax)
        case 1: frameInterval = min(frameInterval + frameIntervalStep, frameIntervalMax)
        case 2: peakFallSpeed = max(peakFallSpeed - peakFallStep, peakFallMin)
        default: break
        }
    case 3: // style
        switch item {
        case 0: themeIndex = (themeIndex + 1) % themes.count
        case 1: fxMirror.toggle()
        case 2: fxFlip.toggle()
        case 3: fxShadow.toggle()
        case 4: fxGlow.toggle()
        case 5: fxPeaks.toggle()
        default: break
        }
    default: break
    }
    markDirty()
}

func handleDown() {
    let tab = activeTab; let item = activeItem
    switch tab {
    case 0:
        gain = max(gain - gainStep, gainMin)
    case 1:
        switch item {
        case 0: barWidth = max(barWidth - 1, barWidthMin)
        case 1: barGap = max(barGap - 1, barGapMin)
        default: break
        }
    case 2:
        switch item {
        case 0: smoothing = max(smoothing - smoothingStep, smoothingMin)
        case 1: frameInterval = max(frameInterval - frameIntervalStep, frameIntervalMin)
        case 2: peakFallSpeed = min(peakFallSpeed + peakFallStep, peakFallMax)
        default: break
        }
    case 3:
        switch item {
        case 0: themeIndex = (themeIndex - 1 + themes.count) % themes.count
        case 1: fxMirror.toggle()
        case 2: fxFlip.toggle()
        case 3: fxShadow.toggle()
        case 4: fxGlow.toggle()
        case 5: fxPeaks.toggle()
        default: break
        }
    default: break
    }
    markDirty()
}

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
                case UInt8(ascii: "\t"):
                    settingsLock.lock()
                    activeTab = (activeTab + 1) % menuTabs.count
                    activeItem = 0
                    settingsLock.unlock()
                case UInt8(ascii: "`"):
                    settingsLock.lock()
                    activeTab = (activeTab - 1 + menuTabs.count) % menuTabs.count
                    activeItem = 0
                    settingsLock.unlock()
                default: break
                }
            } else if n == 3 && buf[0] == 0x1B && buf[1] == 0x5B {
                settingsLock.lock()
                if buf[2] == 0x41 { // up
                    handleUp()
                } else if buf[2] == 0x42 { // down
                    handleDown()
                } else if buf[2] == 0x43 { // right
                    let maxItems = menuTabs[activeTab].paramCount
                    activeItem = (activeItem + 1) % maxItems
                } else if buf[2] == 0x44 { // left
                    let maxItems = menuTabs[activeTab].paramCount
                    activeItem = (activeItem - 1 + maxItems) % maxItems
                }
                settingsLock.unlock()
            }
        }
    }
}

// ── status bar helpers ──────────────────────────────────────────────────────
func miniBar(_ fraction: Float, width: Int, fill: String, empty: String) -> String {
    let filled = Int(fraction * Float(width))
    let rest = width - filled
    return fill + String(repeating: "━", count: filled) + empty + String(repeating: "╌", count: rest)
}

func sliderDisplay(name: String, value: String, fraction: Float, barW: Int, isActive: Bool) -> String {
    let lc = isActive ? activeLabel : labelColor
    let vc = isActive ? activeValue : valueColor
    let fc = isActive ? activeValue : barFillColor
    let ec = barEmptyColor
    let indicator = isActive ? "\(activeLabel)▸ " : "  "
    return "\(indicator)\(lc)\(name) \(vc)\(value) \(miniBar(fraction, width: barW, fill: fc, empty: ec))\(resetColor)"
}

func toggleDisplay(name: String, isOn: Bool, isActive: Bool) -> String {
    let lc = isActive ? activeLabel : labelColor
    let indicator = isActive ? "\(activeLabel)▸ " : "  "
    let stateColor = isOn ? onColor : offColor
    let stateText = isOn ? "on" : "off"
    let dot = isOn ? "●" : "○"
    return "\(indicator)\(lc)\(name) \(stateColor)\(dot) \(stateText)\(resetColor)"
}

func themeDisplay(theme: Theme, isActive: Bool) -> String {
    let lc = isActive ? activeLabel : labelColor
    let vc = isActive ? activeValue : valueColor
    let indicator = isActive ? "\(activeLabel)▸ " : "  "
    var swatch = ""
    for i in 0..<8 {
        let f = Float(i) / 7.0
        let color = colorForHeight(f, theme: theme)
        swatch += "\(color)█"
    }
    return "\(indicator)\(lc)theme \(vc)\(theme.name) \(swatch)\(resetColor)"
}

// ── FFT ─────────────────────────────────────────────────────────────────────
func logBandEdges(nBands: Int, nFFT: Int, sr: Double) -> [Int] {
    var edges = [Int]()
    let logMin = log10(minFreq); let logMax = log10(maxFreq)
    for i in 0...nBands {
        let freq = pow(10, logMin + (logMax - logMin) * Float(i) / Float(nBands))
        edges.append(min(Int(freq * Float(nFFT) / Float(sr)), nFFT / 2))
    }
    return edges
}

// ── main render ─────────────────────────────────────────────────────────────
func processAudio(_ samples: [Float]) {
    let now = CFAbsoluteTimeGetCurrent()
    settingsLock.lock()
    let interval = frameInterval
    settingsLock.unlock()
    if interval > 0 && (now - lastFrameTime) < interval { return }
    lastFrameTime = now

    settingsLock.lock()
    let cGain = gain; let cBarW = barWidth; let cBarGap = barGap
    let cSmooth = smoothing; let cPeakFall = peakFallSpeed
    let cFrameInt = frameInterval; let cTab = activeTab; let cItem = activeItem
    let cTheme = themes[themeIndex]
    let cMirror = fxMirror; let cFlip = fxFlip; let cShadow = fxShadow
    let cGlow = fxGlow; let cPeaks = fxPeaks
    settingsLock.unlock()

    let (cols, rows) = termSize()
    let bandStride = cBarW + cBarGap
    let nBands = max(1, cols / max(1, bandStride))
    let n = min(samples.count, fftSize)

    if fftSetup == nil {
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }
    guard let setup = fftSetup else { return }

    var windowed = [Float](repeating: 0, count: fftSize)
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    for i in 0..<n { windowed[i] = samples[i] * window[i] }

    let halfN = fftSize / 2
    var inR = [Float](repeating: 0, count: halfN)
    var inI = [Float](repeating: 0, count: halfN)
    for i in 0..<halfN { inR[i] = windowed[2*i]; inI[i] = windowed[2*i+1] }

    var outR = [Float](repeating: 0, count: halfN)
    var outI = [Float](repeating: 0, count: halfN)
    vDSP_DFT_Execute(setup, &inR, &inI, &outR, &outI)

    var magnitudes = [Float](repeating: 0, count: halfN)
    for i in 0..<halfN {
        let mag = sqrt(outR[i]*outR[i] + outI[i]*outI[i])
        magnitudes[i] = 20 * log10(max(mag / Float(fftSize), 1e-10))
    }

    let edges = logBandEdges(nBands: nBands, nFFT: fftSize, sr: sampleRate)
    var bands = [Float](repeating: floorDB, count: nBands)
    for i in 0..<nBands {
        let lo = edges[i]; var hi = edges[i+1]
        if hi <= lo { hi = lo + 1 }
        if lo < halfN { bands[i] = magnitudes[lo..<min(hi, halfN)].max() ?? floorDB }
    }

    if prevBands.count != nBands {
        prevBands = [Float](repeating: 0, count: nBands)
        peakBands = [Float](repeating: 0, count: nBands)
        shadowTrail = Array(repeating: [Float](repeating: 0, count: nBands), count: shadowDepth)
        shadowIndex = 0
    }

    var norm = [Float](repeating: 0, count: nBands)
    for i in 0..<nBands {
        let v = ((bands[i] * cGain) - floorDB) / (ceilDB - floorDB)
        norm[i] = cSmooth * prevBands[i] + (1 - cSmooth) * max(0, min(1, v))
    }
    prevBands = norm

    // glow: wider radius, stronger blend into neighbors
    var glowed = norm
    if cGlow {
        for i in 0..<nBands {
            var sum = norm[i] * 1.0
            var weight: Float = 1.0
            for offset in 1...3 {
                let w: Float = [0, 0.6, 0.3, 0.1][offset]
                if i - offset >= 0 { sum += norm[i - offset] * w; weight += w }
                if i + offset < nBands { sum += norm[i + offset] * w; weight += w }
            }
            glowed[i] = max(norm[i], sum / weight)  // glow only adds, never reduces
        }
    }

    // shadow trail: store every frame
    if cShadow {
        shadowTrail[shadowIndex % shadowDepth] = glowed
        shadowIndex += 1
    }

    // compute shadow envelope: max of recent frames with decay
    var shadowEnvelope = [Float](repeating: 0, count: nBands)
    if cShadow {
        for s in 0..<shadowDepth {
            let age = (shadowIndex - 1 - s + shadowDepth * 100) % shadowDepth
            let frame = shadowTrail[age % shadowDepth]
            // newer frames are brighter, older fade out
            let fade: Float = Float(shadowDepth - s) / Float(shadowDepth)
            let brightness = fade * fade  // quadratic falloff for smoother decay
            for i in 0..<min(nBands, frame.count) {
                shadowEnvelope[i] = max(shadowEnvelope[i], frame[i] * brightness)
            }
        }
    }

    // peaks
    if cPeaks {
        for i in 0..<nBands {
            if glowed[i] > peakBands[i] { peakBands[i] = glowed[i] }
            else { peakBands[i] = max(peakBands[i] - cPeakFall, 0) }
        }
    }

    // ── render ──────────────────────────────────────────────────────────────
    let statusHeight = 3
    let height = rows - 1 - statusHeight
    if height < 2 { return }
    let nChars = barChars.count - 1

    var output = "\u{1B}[H"
    output.reserveCapacity(cols * (height + statusHeight) * 18)

    let peakStop = cTheme.stops[3]
    let peakCol = "\u{1B}[38;2;\(Int(peakStop.r));\(Int(peakStop.g));\(Int(peakStop.b))m"

    for row in stride(from: height, through: 1, by: -1) {
        var col = 0

        // mirror: bars grow from center outward in both directions
        // flip: bars hang from the top
        // normal: bars grow from bottom
        let normalizedRow: Float   // 0 = bar base, 1 = bar tip (for threshold)
        let colorRow: Float        // 0..1 for color gradient (0=base, 1=tip)
        let isFlippedHalf: Bool    // true if partial chars should be inverted

        if cMirror {
            let halfH = Float(height) / 2.0
            let distFromCenter = abs(Float(row) - halfH - 0.5)
            normalizedRow = distFromCenter / halfH
            colorRow = normalizedRow
            isFlippedHalf = Float(row) > halfH  // top half has inverted partials
        } else if cFlip {
            normalizedRow = Float(height - row + 1) / Float(height)
            colorRow = normalizedRow
            isFlippedHalf = true
        } else {
            normalizedRow = Float(row) / Float(height)
            colorRow = 1.0 - Float(row - 1) / Float(height)
            isFlippedHalf = false
        }

        let threshold = normalizedRow
        let color = colorForHeight(colorRow, theme: cTheme)
        let gapColor = cBarGap > 0 ? dimColorForHeight(colorRow, theme: cTheme) : ""

        output.append(color)
        for i in 0..<nBands {
            let val = glowed[i]
            let peak = cPeaks ? peakBands[i] : Float(0)
            let shadow = cShadow ? shadowEnvelope[i] : Float(0)

            // peak indicator position
            let isPeak: Bool
            if cPeaks && peak > 0.02 && val < threshold {
                let step = 1.0 / Float(height)
                isPeak = peak >= (threshold - step) && peak < threshold
            } else {
                isPeak = false
            }

            // shadow: visible where shadow envelope exceeds threshold but current bar doesn't
            let inShadow = cShadow && shadow >= threshold && val < threshold

            // how far into the "partial row" is the bar tip?
            let step = 1.0 / Float(height)
            let inPartialRow = val >= (threshold - step) && val < threshold

            for _ in 0..<cBarW {
                if isPeak {
                    output.append(peakCol)
                    output.append(peakChar)
                    output.append(color)
                } else if val >= threshold {
                    output.append(barChars[nChars])
                } else if inPartialRow {
                    let frac = (val - (threshold - step)) / step
                    if isFlippedHalf {
                        // inverted partial: ▇▆▅...▁ instead of ▁▂▃...█
                        let idx = nChars - Int(frac * Float(nChars))
                        output.append(barChars[max(0, min(idx, nChars))])
                    } else {
                        let idx = Int(frac * Float(nChars))
                        output.append(barChars[max(0, min(idx, nChars))])
                    }
                } else if inShadow {
                    // shadow glow: render as dim bar block with decay
                    let shadowStrength = (shadow - threshold + 0.1) / shadow  // 0..1
                    let fade = max(0.15, min(0.45, shadowStrength))
                    let (sr, sg, sb) = rgbForHeight(colorRow, theme: cTheme)
                    output.append("\u{1B}[38;2;\(Int(Float(sr)*fade));\(Int(Float(sg)*fade));\(Int(Float(sb)*fade))m")
                    output.append("░")
                    output.append(color)
                } else {
                    output.append(" ")
                }
                col += 1
            }

            if cBarGap > 0 {
                output.append(gapColor)
                for _ in 0..<cBarGap { output.append(" "); col += 1 }
                output.append(color)
            }
        }
        while col < cols { output.append(" "); col += 1 }
        output.append(resetColor)
        if row > 1 { output.append("\n") }
    }

    // ── status bar ──────────────────────────────────────────────────────────
    // line 1: tab bar
    var tabLine = ""
    for (i, tab) in menuTabs.enumerated() {
        let isActiveTab = (i == cTab)
        if isActiveTab {
            tabLine += " \(activeLabel)[\(activeValue)\(tab.name)\(activeLabel)]\(resetColor)"
        } else {
            tabLine += " \(dimColor) \(labelColor)\(tab.name)\(dimColor) \(resetColor)"
        }
        if i < menuTabs.count - 1 { tabLine += " \(dimColor)·\(resetColor)" }
    }

    // line 2: items for active tab
    let barW = 8
    var itemsLine = ""
    switch cTab {
    case 0: // audio
        let gainFrac = (cGain - gainMin) / (gainMax - gainMin)
        itemsLine = sliderDisplay(name: "gain", value: String(format: "%3.0f%%", gainFrac * 100), fraction: gainFrac, barW: barW, isActive: cItem == 0)
    case 1: // bars
        let wFrac = Float(cBarW - barWidthMin) / Float(max(1, barWidthMax - barWidthMin))
        let gFrac = Float(cBarGap - barGapMin) / Float(max(1, barGapMax - barGapMin))
        let items = [
            sliderDisplay(name: "width", value: "\(cBarW)", fraction: wFrac, barW: barW, isActive: cItem == 0),
            sliderDisplay(name: "gap", value: "\(cBarGap)", fraction: gFrac, barW: barW, isActive: cItem == 1),
        ]
        itemsLine = items.joined(separator: "  \(dimColor)│\(resetColor)  ")
    case 2: // motion
        let sFrac = (cSmooth - smoothingMin) / (smoothingMax - smoothingMin)
        let fps = cFrameInt > 0 ? String(format: "%.0f", 1.0 / cFrameInt) : "max"
        let fFrac = Float(cFrameInt - frameIntervalMin) / Float(frameIntervalMax - frameIntervalMin)
        let pFrac = 1.0 - (cPeakFall - peakFallMin) / (peakFallMax - peakFallMin)
        let items = [
            sliderDisplay(name: "smooth", value: String(format: "%.0f%%", sFrac * 100), fraction: sFrac, barW: barW, isActive: cItem == 0),
            sliderDisplay(name: "rate", value: "\(fps)fps", fraction: fFrac, barW: barW, isActive: cItem == 1),
            sliderDisplay(name: "peak-fall", value: String(format: "%.0f%%", pFrac * 100), fraction: pFrac, barW: barW, isActive: cItem == 2),
        ]
        itemsLine = items.joined(separator: "  \(dimColor)│\(resetColor)  ")
    case 3: // style
        let items = [
            themeDisplay(theme: cTheme, isActive: cItem == 0),
            toggleDisplay(name: "mirror", isOn: cMirror, isActive: cItem == 1),
            toggleDisplay(name: "flip", isOn: cFlip, isActive: cItem == 2),
            toggleDisplay(name: "shadow", isOn: cShadow, isActive: cItem == 3),
            toggleDisplay(name: "glow", isOn: cGlow, isActive: cItem == 4),
            toggleDisplay(name: "peaks", isOn: cPeaks, isActive: cItem == 5),
        ]
        itemsLine = items.joined(separator: "  \(dimColor)│\(resetColor)  ")
    default: break
    }

    let helpLine = "\(dimColor)  tab switch menu   ←→ select   ↑↓ adjust   q quit\(resetColor)"

    output.append("\n" + tabLine + String(repeating: " ", count: max(0, cols - 50)))
    output.append("\n" + itemsLine + String(repeating: " ", count: max(0, cols - 10)))
    output.append("\n" + helpLine + String(repeating: " ", count: max(0, cols - 55)))

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
        guard let display = content.displays.first else { print("No display found"); exit(1) }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = false
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0; var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let data = dataPointer else { return }
        let floatCount = length / MemoryLayout<Float>.size
        let floatPtr = data.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: floatCount))
        }
        processAudio(floatPtr)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cleanup(); print("\nStream stopped: \(error.localizedDescription)"); exit(1)
    }
}

// ── lifecycle ───────────────────────────────────────────────────────────────
func cleanup() {
    settingsLock.lock()
    if settingsDirty { saveSettings() }
    settingsLock.unlock()
    disableRawMode(); showCursor()
}

signal(SIGINT) { _ in cleanup(); exit(0) }
signal(SIGTERM) { _ in cleanup(); exit(0) }

loadSettings()
hideCursor()
clearScreen()
startKeyboardListener()

let capture = AudioCapture()
Task {
    do { try await capture.start() }
    catch {
        cleanup()
        print("Failed to start capture: \(error.localizedDescription)")
        print("Grant Screen Recording permission in System Settings → Privacy & Security.")
        exit(1)
    }
}
RunLoop.main.run()
