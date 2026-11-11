import AVFoundation
import ClearMixCore
import Foundation

// Command line probe for the microphone chain: mic → RNNoise → virtual mic.
// It is deliberately small; the app will drive the same MicEngine.

private let usage = """
clearmix-mic — mikrofon temizleme hattı

KULLANIM
  clearmix-mic list
  clearmix-mic run [seçenekler]

SEÇENEKLER
  --input <ad|uid>      Giriş cihazı (varsayılan: sistem mikrofonu)
  --output <ad|uid>     Çıkış cihazı (varsayılan: BlackHole 2ch, yoksa sistem çıkışı)
  --seconds <saniye>    Belirtilen süre sonra dur (0 = Ctrl-C'ye kadar, varsayılan 0)
  --denoise <on|off>    RNNoise gürültü temizleme (varsayılan on)
  --gate <on|off>       Gürültü kapısı (varsayılan off)
  --gain <dB>           Giriş kazancı (varsayılan 0)
  --buffer <kare>       Giriş/çıkış cihaz tamponunu ayarla (0 = dokunma)
  --input-buffer <kare> Yalnızca mikrofon (giriş) tamponunu ayarla
  --mute                Cihaz çıkışını sessize al (yankıyı önler)
  --record <dosya.wav>  İşlenmiş sesi 48 kHz mono WAV olarak kaydet

ÖRNEK
  clearmix-mic run --seconds 10 --record /tmp/temiz.wav
  clearmix-mic run --mute --record /tmp/temiz.wav   # görüşme sırasında güvenli
"""

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func listDevices() {
    let devices = AudioDevices.all()
    let defaultInputID = AudioDevices.defaultInput()?.id
    let defaultOutputID = AudioDevices.defaultOutput()?.id

    print("Girişler")
    let inputs = devices.filter(\.hasInput)
    if inputs.isEmpty { print("  (yok)") }
    for device in inputs {
        var tags: [String] = []
        if device.id == defaultInputID { tags.append("varsayılan mikrofon") }
        if device.isBlackHole { tags.append("BlackHole") }
        print("  \(device.name) — \(device.inputChannels) kanal, \(Int(device.nominalSampleRate)) Hz"
              + (tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"))
    }

    print("")
    print("Çıkışlar")
    let outputs = devices.filter(\.hasOutput)
    if outputs.isEmpty { print("  (yok)") }
    for device in outputs {
        var tags: [String] = []
        if device.id == defaultOutputID { tags.append("varsayılan çıkış") }
        if device.isBlackHole { tags.append("BlackHole") }
        print("  \(device.name) — \(device.outputChannels) kanal, \(Int(device.nominalSampleRate)) Hz"
              + (tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"))
    }

    print("")
    if let blackHole = AudioDevices.blackHole() {
        print("BlackHole hazır: \(blackHole.name)")
        print("Discord/Zoom/OBS'de giriş cihazı olarak bunu seçin.")
    } else {
        print("BlackHole bulunamadı. Kurulum: brew install --cask blackhole-2ch")
    }
}

// MARK: - Arguments

private struct Options {
    var inputQuery: String?
    var outputQuery: String?
    var seconds = 0.0
    var denoise = true
    var gate = false
    var gainDB: Float = 0
    var bufferFrames = 0
    var inputBufferFrames = 0
    var mute = false
    var recordPath: String?
}

private func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let key = arguments[index]
        func value() -> String {
            guard index + 1 < arguments.count else { fail("\(key) için değer yok") }
            index += 1
            return arguments[index]
        }
        switch key {
        case "--input": options.inputQuery = value()
        case "--output": options.outputQuery = value()
        case "--seconds": options.seconds = Double(value()) ?? 0
        case "--denoise": options.denoise = value().lowercased() != "off"
        case "--gate": options.gate = value().lowercased() == "on"
        case "--gain": options.gainDB = Float(value()) ?? 0
        case "--buffer": options.bufferFrames = Int(value()) ?? 0
        case "--input-buffer": options.inputBufferFrames = Int(value()) ?? 0
        case "--mute": options.mute = true
        case "--record": options.recordPath = value()
        case "-h", "--help": print(usage); exit(0)
        default: fail("bilinmeyen seçenek: \(key)\n\n\(usage)")
        }
        index += 1
    }
    return options
}

// MARK: - Recording

/// Drains the monitor ring on a plain thread and writes a 48 kHz mono WAV.
private final class Recorder: @unchecked Sendable {
    /// Released on stop: AVAudioFile flushes its buffer in `deinit`, and a
    /// running command line tool that exits with a live file writes nothing.
    private var audioFile: AVAudioFile?
    private let ring: AudioRingBuffer
    private let queue = DispatchQueue(label: "clearmix.recorder")
    private var running = true

    init?(path: String, ring: AudioRingBuffer) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MicChain.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let file = try? AVAudioFile(
            forWriting: URL(fileURLWithPath: path),
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else { return nil }
        audioFile = file
        self.ring = ring
    }

    func start() {
        queue.async {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: MicChain.sampleRate,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800) else {
                return
            }
            while self.running {
                let frames = self.ring.read(frames: 4_800)
                if frames.isEmpty {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                buffer.frameLength = AVAudioFrameCount(frames.count)
                if let channel = buffer.floatChannelData?[0] {
                    frames.withUnsafeBufferPointer { source in
                        channel.update(from: source.baseAddress!, count: frames.count)
                    }
                }
                try? self.audioFile?.write(from: buffer)
            }
        }
    }

    func stop() {
        running = false
        queue.sync {}
        audioFile = nil
    }
}

private final class RecorderHolder {
    nonisolated(unsafe) static var shared: Recorder?
}

// MARK: - Main

private let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "run"

if command == "list" {
    listDevices()
    exit(0)
}
if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}
guard command == "run" else {
    fail("bilinmeyen komut: \(command)\n\n\(usage)")
}

private let options = parse(Array(arguments.dropFirst()))

private let inputDevices = AudioDevices.inputs()
private let inputDevice: AudioDevice
if let query = options.inputQuery {
    guard let found = AudioDevices.find(query, in: inputDevices) else {
        listDevices()
        fail("giriş cihazı bulunamadı: \(query)")
    }
    inputDevice = found
} else {
    guard let fallback = AudioDevices.defaultInput() else { fail("mikrofon bulunamadı") }
    inputDevice = fallback
}

private let outputDevices = AudioDevices.outputs()
private let outputDevice: AudioDevice
if let query = options.outputQuery {
    guard let found = AudioDevices.find(query, in: outputDevices) else {
        listDevices()
        fail("çıkış cihazı bulunamadı: \(query)")
    }
    outputDevice = found
} else if let blackHole = AudioDevices.blackHole() {
    outputDevice = blackHole
} else {
    guard let fallback = AudioDevices.defaultOutput() else { fail("çıkış cihazı bulunamadı") }
    outputDevice = fallback
    print("not: BlackHole 2ch bulunamadı, çıkış \"\(fallback.name)\" üzerinden yapılıyor.")
    print("     Sanal mikrofon için: brew install --cask blackhole-2ch\n")
}

guard let chain = MicChain(
    inputSampleRate: inputDevice.nominalSampleRate,
    channels: inputDevice.inputChannels
) else {
    fail("RNNoise başlatılamadı")
}

/// Device buffers are a HAL-wide setting other apps share, so put back what we
/// found when this runs out.
private var restoreDeviceBuffers: () -> Void = {}

if options.bufferFrames > 0 || options.inputBufferFrames > 0 {
    let savedInput = inputDevice.bufferFrameSize
    let savedOutput = outputDevice.bufferFrameSize
    let frames = options.bufferFrames > 0 ? options.bufferFrames : options.inputBufferFrames
    let touchOutput = options.bufferFrames > 0

    let inputBuffer = AudioDevices.setBufferFrameSize(frames, for: inputDevice.id)
    let outputBuffer = touchOutput
        ? AudioDevices.setBufferFrameSize(frames, for: outputDevice.id)
        : savedOutput
    print("tampon: giriş \(inputBuffer) kare, çıkış \(outputBuffer) kare (çıkışta geri alınacak)")

    restoreDeviceBuffers = {
        AudioDevices.setBufferFrameSize(savedInput, for: inputDevice.id)
        if touchOutput {
            AudioDevices.setBufferFrameSize(savedOutput, for: outputDevice.id)
        }
        print("tampon geri alındı: giriş \(inputDevice.bufferFrameSize) kare, "
              + "çıkış \(outputDevice.bufferFrameSize) kare")
    }
}

var configuration = MicEngine.Configuration(inputDevice: inputDevice, outputDevice: outputDevice)
configuration.denoiseEnabled = options.denoise
configuration.gateEnabled = options.gate
configuration.gainDB = options.gainDB
configuration.muteOutput = options.mute

if let path = options.recordPath {
    let monitor = AudioRingBuffer(capacityFrames: 96_000, channels: 1)
    configuration.monitorRing = monitor
    guard let recorder = Recorder(path: path, ring: monitor) else {
        fail("kayıt dosyası oluşturulamadı: \(path)")
    }
    RecorderHolder.shared = recorder
    recorder.start()
}

private let engine: MicEngine
do {
    engine = try MicEngine(configuration: configuration)
} catch {
    fail("motor kurulamadı: \(error.localizedDescription)")
}

signal(SIGINT, SIG_IGN)
let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruption.setEventHandler {
    RecorderHolder.shared?.stop()
    engine.stop()
    restoreDeviceBuffers()
    exit(0)
}
interruption.resume()

private func chainLatencyMS() -> Double {
    Double(chain.latencyFrames) / MicChain.sampleRate * 1_000
}

print("ClearMix mikrofon hattı")
print("  giriş    : \(inputDevice.name) — \(Int(inputDevice.nominalSampleRate)) Hz, \(inputDevice.inputChannels) kanal")
print("  çıkış    : \(outputDevice.name) — \(Int(outputDevice.nominalSampleRate)) Hz, \(outputDevice.outputChannels) kanal")
print("  zincir   : RNNoise \(options.denoise ? "açık" : "kapalı"), kapı \(options.gate ? "açık" : "kapalı"), kazanç \(options.gainDB) dB")
if options.mute {
    print("  çıkış    : sessiz (cihaz yalnızca saat olarak kullanılıyor)")
}
print("  gecikme  : zincir ~\(String(format: "%.1f", chainLatencyMS())) ms (hedef < 40 ms)")

do {
    try engine.start()
    if abs(engine.outputSampleRate - MicChain.sampleRate) > 0.5 {
        print("  not      : çıkış \(Int(engine.outputSampleRate)) Hz, 48 kHz'ten yeniden örnekleniyor")
    }
} catch {
    fail("başlatılamadı: \(error.localizedDescription)")
}

print("  durum    : çalışıyor\(options.seconds > 0 ? " (\(Int(options.seconds)) sn)" : " (Ctrl-C ile dur)")")
print("")

let started = Date()
var lastReport = started
var lastSnapshot = engine.stats.snapshot

while true {
    Thread.sleep(forTimeInterval: 0.1)
    let now = Date()
    if now.timeIntervalSince(lastReport) >= 1 {
        let snapshot = engine.stats.snapshot
        let inDB = AudioMath.linearToDb(engine.chain.inputPeak)
        let outDB = AudioMath.linearToDb(engine.chain.outputPeak)
        let fillMS = Double(snapshot.fillFrames) / max(engine.inputSampleRate, 1) * 1_000
        let underruns = snapshot.underrunFrames &- lastSnapshot.underrunFrames
        let overruns = snapshot.overrunFrames &- lastSnapshot.overrunFrames
        let inPerSecond = snapshot.framesIn &- lastSnapshot.framesIn
        print(String(
            format: "  giriş %6.1f dBFS → %6.1f dBFS | ses %.2f | okunan %llu/s | bekleyen %d | düşen %d | tampon %5.1f ms | kayma %+.3f%% | alt besleme %llu, taşma %llu | gecikme ~%.1f ms",
            inDB, outDB,
            Double(engine.chain.voiceProbability),
            inPerSecond,
            engine.chain.pendingCount,
            engine.chain.droppedFrames,
            fillMS,
            (engine.chain.driftStep - 1) * 100,
            underruns, overruns,
            engine.estimatedLatency * 1_000
        ))
        lastSnapshot = snapshot
        lastReport = now
    }
    if options.seconds > 0, now.timeIntervalSince(started) >= options.seconds {
        break
    }
}

RecorderHolder.shared?.stop()
engine.stop()
restoreDeviceBuffers()
Thread.sleep(forTimeInterval: 0.2)
let final = engine.stats.snapshot
print("")
print(String(
    format: "bitti — %.1f sn işlendi, toplam alt besleme %llu kare, taşma %llu kare, kayma düzeltmesi %+.3f%%",
    Double(final.framesOut) / MicChain.sampleRate,
    final.underrunFrames, final.overrunFrames,
    (engine.chain.driftStep - 1) * 100
))
print("giriş tamponu şu an \(inputDevice.bufferFrameSize) kare")
if let path = options.recordPath {
    print("kayıt: \(path)")
}
