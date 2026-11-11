import ClearMixCore
import Foundation

// Command line probe for the mixer core: every playing app gets its own tap,
// slider and meter, and all of it is played back through one output device.
// The menu bar UI will drive the same MixerEngine.

private let usage = """
clearmix-mix — uygulama bazlı ses mikseri

KULLANIM
  clearmix-mix list [--all]
  clearmix-mix run [seçenekler]

SEÇENEKLER
  --output <ad|uid>        Çıkış cihazı (varsayılan: sistem çıkışı)
  --only <ad|paket>        Yalnızca bu uygulamaları karıştır (birden çok kez)
  --exclude <ad|paket>     Bu uygulamaları atla (birden çok kez)
  --gain <ad|paket>=<dB>   Uygulama kazancı, örn. --gain Spotify=-6
  --mute <ad|paket>        Uygulamayı sessize al
  --seconds <saniye>       Belirtilen süre sonra dur (0 = Ctrl-C'ye kadar)
  --mic                    Temizlenmiş mikrofonu da aynı çıkışa karıştır
  --input <ad|uid>         Mikrofon cihazı (varsayılan: sistem mikrofonu)
  --denoise <on|off>       RNNoise gürültü temizleme (varsayılan on)
  --gate <on|off>          Gürültü kapısı (varsayılan off)
  --mic-gain <dB>          Mikrofon kazancı (varsayılan 0)
  --no-monitor             Mikrofonu hoparlöre verme (yalnızca ring/BlackHole)
  --quiet                  Ölçer satırını yazdırma
  --log <dosya>            Ölçer satırlarını dosyaya da yaz (`.app` ile çalıştırırken)

ÖRNEK
  clearmix-mix list
  clearmix-mix run --seconds 15 --gain discord=-3 --mute Safari
"""

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func list(includeSilent: Bool) {
    let processes = includeSilent ? AudioProcesses.all() : AudioProcesses.playingOutput()
    print(includeSilent ? "Ses nesneleri" : "Şu anda ses çalan uygulamalar")
    if processes.isEmpty { print("  (yok)") }
    for process in processes.sorted(by: { $0.name < $1.name }) {
        var tags: [String] = []
        if process.isRunningOutput { tags.append("çalıyor") }
        if process.isRunningInput { tags.append("kayıt") }
        if !tags.isEmpty { tags.append(contentsOf: []) }
        print(
            "  \(process.name)  [\(process.bundleID ?? "-")]  pid \(process.pid)"
                + (tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))")
        )
    }
    print("")
    guard let output = AudioDevices.defaultOutput() else {
        print("Çıkış cihazı yok.")
        return
    }
    print("Varsayılan çıkış: \(output.name) — \(output.outputChannels) kanal, \(Int(output.nominalSampleRate)) Hz")
}

private struct Options {
    var outputQuery: String?
    var only: [String] = []
    var exclude: [String] = []
    var gains: [(query: String, db: Float)] = []
    var mutes: [String] = []
    var seconds = 0.0
    var quiet = false
    var logPath: String?
    var micEnabled = false
    var inputQuery: String?
    var denoise = true
    var gate = false
    var micGainDB: Float = 0
    var monitor = true
}

private func parse(_ arguments: [String]) -> (Options, isList: Bool, includeSilent: Bool) {
    var options = Options()
    var isList = false
    var includeSilent = false
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        func value() -> String {
            guard index + 1 < arguments.count else { fail("\(key) için değer yok") }
            index += 1
            return arguments[index]
        }
        switch key {
        case "list":
            isList = true
        case "run":
            break
        case "--all":
            includeSilent = true
        case "--output":
            options.outputQuery = value()
        case "--only":
            options.only.append(contentsOf: value().split(separator: ",").map(String.init))
        case "--exclude":
            options.exclude.append(contentsOf: value().split(separator: ",").map(String.init))
        case "--gain":
            let spec = value()
            let parts = spec.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let db = Float(parts[1]) else {
                fail("--gain biçimi: <uygulama>=<dB>, örn. Spotify=-6")
            }
            options.gains.append((String(parts[0]), db))
        case "--mute":
            options.mutes.append(value())
        case "--seconds":
            options.seconds = Double(value()) ?? 0
        case "--quiet":
            options.quiet = true
        case "--log":
            options.logPath = value()
        case "--mic":
            options.micEnabled = true
        case "--input":
            options.inputQuery = value()
        case "--denoise":
            options.denoise = value().lowercased() != "off"
        case "--gate":
            options.gate = value().lowercased() == "on"
        case "--mic-gain":
            options.micGainDB = Float(value()) ?? 0
        case "--no-monitor":
            options.monitor = false
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("bilinmeyen seçenek: \(key)\n\n\(usage)")
        }
        index += 1
    }
    return (options, isList, includeSilent)
}

private func meter(_ value: Float, width: Int = 20) -> String {
    let db = value > 0 ? 20 * log10(value) : -120
    let filled = value <= 0 ? 0 : min(width, Int((db + 60) / 60 * Float(width)))
    return String(repeating: "█", count: max(0, filled))
        + String(repeating: "·", count: max(0, width - filled))
}

// MARK: - Run

private let (options, isList, includeSilent) = parse(Array(CommandLine.arguments.dropFirst()))

if isList {
    list(includeSilent: includeSilent)
    exit(0)
}

guard let outputDevice = options.outputQuery.flatMap({
    AudioDevices.find($0, in: AudioDevices.outputs())
}) ?? AudioDevices.defaultOutput() else {
    fail("Çıkış cihazı bulunamadı.")
}

var inputDevice: AudioDevice?
if options.micEnabled {
    inputDevice = options.inputQuery.flatMap {
        AudioDevices.find($0, in: AudioDevices.inputs())
    } ?? AudioDevices.defaultInput()
    guard inputDevice != nil else { fail("Mikrofon bulunamadı.") }
}

var sessionConfiguration = MixSession.Configuration(
    inputDevice: inputDevice,
    outputDevice: outputDevice
)
sessionConfiguration.only = options.only
sessionConfiguration.excluding = options.exclude
sessionConfiguration.denoiseEnabled = options.denoise
sessionConfiguration.gateEnabled = options.gate
sessionConfiguration.micGainDB = options.micGainDB
sessionConfiguration.monitorMicrophone = options.monitor
let engine = MixSession(configuration: sessionConfiguration)

print("Çıkış: \(outputDevice.name) — \(outputDevice.outputChannels) kanal, \(Int(outputDevice.nominalSampleRate)) Hz")

if let inputDevice, options.micEnabled {
    do {
        try engine.startMicrophone(device: inputDevice)
        print("Mikrofon: \(inputDevice.name) — \(inputDevice.inputChannels) kanal, \(Int(inputDevice.nominalSampleRate)) Hz"
              + (options.monitor ? "" : "  (hoparlöre verilmiyor)"))
    } catch {
        fail("Mikrofon başlatılamadı: \(error.localizedDescription)")
    }
}

engine.syncApplications()
if engine.taps.isEmpty && !options.micEnabled {
    fail("Şu anda ses çalan uygulama yok. Bir şey oynatıp tekrar deneyin.")
}

// Sliders are applied once per tap, when it is created; an app that starts
// playing later picks its settings up from the sync that discovers it.
private func applyControls(to taps: [AppTap]) {
    for tap in taps {
        for (query, db) in options.gains where matches(tap, query) {
            tap.bus.setGain(decibels: db)
        }
        for query in options.mutes where matches(tap, query) {
            tap.bus.mute()
        }
        print(
            "  + \(tap.process.name) — tap \(Int(tap.tapSampleRate)) Hz, çıkış \(Int(tap.outputSampleRate)) Hz"
        )
    }
}

private func matches(_ tap: AppTap, _ query: String) -> Bool {
    tap.process.name.localizedCaseInsensitiveContains(query)
        || tap.process.bundleID?.localizedCaseInsensitiveContains(query) == true
        || "\(tap.process.pid)" == query
}

applyControls(to: engine.taps)

let wantsApps = !options.quiet

// A bundled app started with `open` has no terminal, so the same lines can go
// to a file for tests.
let logHandle: FileHandle? = options.logPath.flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}

let stopSignal = DispatchSemaphore(value: 0)
signal(SIGINT, SIG_IGN)
let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
source.setEventHandler { stopSignal.signal() }
source.resume()

let started = Date()
var lastSync = Date.distantPast
while true {
    if stopSignal.wait(timeout: .now()) == .success { break }
    if options.seconds > 0, Date().timeIntervalSince(started) >= options.seconds { break }

    if Date().timeIntervalSince(lastSync) >= 0.5 {
        lastSync = Date()
        applyControls(to: engine.syncApplications())
    }

    if wantsApps {
        var lines: [String] = []
        if engine.isMicrophoneRunning {
            let latency = Int(engine.microphoneLatency * 1_000)
            lines.append(
                "\(String(repeating: " ", count: 0))🎙 mikrofon\(meter(engine.microphonePeak)) \(latency) ms gecikme"
            )
        }
        for tap in engine.taps.sorted(by: { $0.process.name < $1.process.name }) {
            let db = tap.bus.gain > 0 ? 20 * log10(tap.bus.gain) : -120
            let state = tap.bus.isMuted ? "sessiz" : String(format: "%+.1f dB", db)
            lines.append(
                "\(tap.process.name.prefix(18).padding(toLength: 18, withPad: " ", startingAt: 0))\(meter(tap.bus.peak)) \(state)"
                    + "  [girdi \(tap.capturedFrames / 48) ms \(tap.capturedPeak > 0 ? String(format: "%.3f", tap.capturedPeak) : "sessiz"), çıkış \(tap.renderedFrames / 48) ms, hata \(tap.lastStatus)]"
            )
        }
        if logHandle == nil {
            let title = "ClearMix mikser — \(engine.taps.count) uygulama"
                + (engine.isMicrophoneRunning ? " + mikrofon" : "")
            print("\u{1B}[2J\u{1B}[H" + title + "\n" + lines.joined(separator: "\n"))
            fflush(stdout)
        } else {
            logHandle?.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

let stats = engine.microphoneStats?.snapshot
let latencyMS = Int(engine.microphoneLatency * 1_000)
engine.stop()
if let stats {
    print("mikrofon: \(stats.framesIn) kare girdi, \(stats.framesOut) kare çıkış, \(stats.overrunFrames) taşma, \(stats.underrunFrames) alt besleme, tahmini gecikme \(latencyMS) ms")
}
print("\nDurdu.")
