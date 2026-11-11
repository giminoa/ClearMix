import AVFoundation
import Accelerate
import ClearMixCore
import Foundation

// Offline harness from the plan: WAV in -> mic chain -> WAV out.
// The chain runs RNNoise first, then the gate, gain and limiter stages.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func usage() -> Never {
    print("""
    usage: clearmix-dsp <input> <output> [options]

      --denoise <on|off>    RNNoise suppression (default on)
      --gain-db <value>     output gain in dB (default 0)
      --gate <value|off>    gate threshold in dBFS (default -45)
      --ceiling-db <value>  limiter ceiling in dBFS (default -1)

    The output is always 48 kHz mono 32-bit float, matching the mic chain.
    """)
    exit(0)
}

func measure(_ samples: UnsafePointer<Float>, count: Int) -> (peak: Float, rms: Float) {
    guard count > 0 else { return (0, 0) }
    var peak: Float = 0
    vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
    var rms: Float = 0
    vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
    return (peak, rms)
}

func format(_ value: Float) -> String {
    String(format: "%+.1f dBFS", AudioMath.linearToDb(value))
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") { usage() }
guard arguments.count >= 2 else { usage() }

let inputURL = URL(fileURLWithPath: arguments.removeFirst())
let outputURL = URL(fileURLWithPath: arguments.removeFirst())

var denoise = true
var gainDB: Float = 0
var gateDB: Float? = -45
var ceilingDB: Float = -1

while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    guard !arguments.isEmpty else { fail("missing value for \(flag)") }
    let value = arguments.removeFirst()
    switch flag {
    case "--denoise":
        switch value.lowercased() {
        case "on", "1", "true", "yes": denoise = true
        case "off", "0", "false", "no": denoise = false
        default: fail("invalid --denoise \(value)")
        }
    case "--gain-db":
        guard let parsed = Float(value) else { fail("invalid --gain-db \(value)") }
        gainDB = parsed
    case "--gate":
        if value.lowercased() == "off" {
            gateDB = nil
        } else {
            guard let parsed = Float(value) else { fail("invalid --gate \(value)") }
            gateDB = parsed
        }
    case "--ceiling-db":
        guard let parsed = Float(value) else { fail("invalid --ceiling-db \(value)") }
        ceilingDB = parsed
    default:
        fail("unknown option \(flag)")
    }
}

if inputURL.standardizedFileURL == outputURL.standardizedFileURL {
    fail("input and output must be different files")
}

// MARK: - Decode

let inputFile: AVAudioFile
do {
    inputFile = try AVAudioFile(forReading: inputURL)
} catch {
    fail("cannot open \(inputURL.path): \(error.localizedDescription)")
}

let sourceFormat = inputFile.processingFormat
let sourceFrames = AVAudioFrameCount(inputFile.length)
guard sourceFrames > 0 else { fail("input file has no audio") }
guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrames) else {
    fail("cannot allocate input buffer")
}
do {
    try inputFile.read(into: sourceBuffer)
} catch {
    fail("cannot read \(inputURL.path): \(error.localizedDescription)")
}

// MARK: - Mono + 48 kHz

func mixdownToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    guard
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frameCount)),
        let source = buffer.floatChannelData,
        let destination = monoBuffer.floatChannelData
    else {
        fail("cannot allocate mono buffer")
    }
    monoBuffer.frameLength = AVAudioFrameCount(frameCount)
    if channelCount == 1 {
        destination[0].update(from: source[0], count: frameCount)
    } else {
        destination[0].initialize(repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            vDSP_vadd(destination[0], 1, source[channel], 1, destination[0], 1, vDSP_Length(frameCount))
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(destination[0], 1, &scale, destination[0], 1, vDSP_Length(frameCount))
    }
    return monoBuffer
}

func resampleTo48k(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let targetRate = 48_000.0
    guard buffer.format.sampleRate != targetRate else { return buffer }
    guard
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: buffer.format, to: targetFormat)
    else {
        fail("cannot create a 48 kHz converter")
    }
    let ratio = targetRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
        fail("cannot allocate resampled buffer")
    }

    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
        if supplied {
            outStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        outStatus.pointee = .haveData
        return buffer
    }
    if status == .error {
        fail("resampling failed: \(conversionError?.localizedDescription ?? "unknown error")")
    }
    return output
}

let mono = mixdownToMono(sourceBuffer)
let working = resampleTo48k(mono)
let inputRate = sourceFormat.sampleRate
let totalFrames = Int(working.frameLength)
guard let channel = working.floatChannelData?[0], totalFrames > 0 else { fail("no samples after conversion") }

// MARK: - Chain

let before = measure(channel, count: totalFrames)

let denoiser: Denoiser?
if denoise {
    guard let created = Denoiser() else { fail("cannot initialise RNNoise") }
    denoiser = created
} else {
    denoiser = nil
}

let gate = NoiseGate(sampleRate: 48_000)
if let gateDB {
    gate.thresholdDB = gateDB
} else {
    gate.isEnabled = false
}
let gain = GainStage(sampleRate: 48_000)
gain.setGain(decibels: gainDB)
gain.snapToTarget()
let limiter = SoftLimiter(sampleRate: 48_000, ceilingDB: ceilingDB)

let blockSize = 480
var offset = 0
// RNNoise needs full 480-sample blocks, so a short tail block is zero padded
// with this scratch buffer instead of reading past the end of the audio.
var tail = [Float](repeating: 0, count: blockSize)
var voiceSum: Float = 0
var voiceBlocks = 0
while offset < totalFrames {
    let frames = min(blockSize, totalFrames - offset)
    let block = channel + offset
    if let denoiser {
        if frames == blockSize {
            voiceSum += denoiser.process(block)
        } else {
            tail.withUnsafeMutableBufferPointer { buffer in
                guard let scratch = buffer.baseAddress else { return }
                scratch.update(from: block, count: frames)
                scratch.advanced(by: frames).update(repeating: 0, count: blockSize - frames)
                voiceSum += denoiser.process(scratch)
                block.update(from: scratch, count: frames)
            }
        }
        voiceBlocks += 1
    }
    gate.process(block, frames: frames)
    gain.process(block, frames: frames)
    limiter.process(block, frames: frames)
    offset += frames
}

let after = measure(channel, count: totalFrames)

// MARK: - Write

let outputSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48_000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]

// The file has to be closed before the process exits or the WAV is left with
// an empty data chunk, so the write happens inside its own scope.
@MainActor
func writeOutput(_ buffer: AVAudioPCMBuffer) {
    do {
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outputFile.write(from: buffer)
    } catch {
        fail("cannot write \(outputURL.path): \(error.localizedDescription)")
    }
}

writeOutput(working)

let seconds = Double(totalFrames) / 48_000.0
print("""
ClearMix DSP check
  input     : \(Int(inputRate)) Hz, \(Int(sourceFormat.channelCount)) ch, \(String(format: "%.2f", seconds)) s
  output    : 48000 Hz, 1 ch
  denoise   : \(denoiser == nil ? "off" : String(format: "on (mean voice %.2f)", voiceBlocks > 0 ? voiceSum / Float(voiceBlocks) : 0))
  gate      : \(gate.isEnabled ? String(format: "%.0f dBFS", gate.thresholdDB) : "off")
  gain      : \(String(format: "%+.1f dB", gainDB))
  ceiling   : \(String(format: "%.1f dBFS", ceilingDB))
  before    : peak \(format(before.peak)) / rms \(format(before.rms))
  after     : peak \(format(after.peak)) / rms \(format(after.rms))
  written   : \(outputURL.path)
""")
