import Foundation

/// Realtime-safe 10-band stereo peaking equalizer for per-app mixer buses.
///
/// Preallocates all filter coefficients and delay lines in `init`. Setting
/// band gains writes plain floats; the audio thread checks for changes at the
/// start of each block and recomputes only changed bands, bypassing completely
/// when all bands are flat (0 dB).
public final class Equalizer: @unchecked Sendable {
    public static let frequencies: [Double] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000,
    ]
    public static let bandCount = frequencies.count
    public static let minGainDB: Float = -12
    public static let maxGainDB: Float = 12

    public enum Preset: String, CaseIterable, Codable, Sendable {
        case flat
        case bassBoost
        case vocal
        case podcast
        case gaming
        case treble
        case night

        public var gainsDB: [Float] {
            switch self {
            case .flat:      return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            case .bassBoost: return [6, 5, 4, 2, 0, 0, 0, 0, 1, 1]
            case .vocal:     return [-3, -2, -1, 1, 3, 4, 4, 2, 1, 0]
            case .podcast:   return [-4, -3, 0, 2, 3, 4, 3, 2, 0, -1]
            case .gaming:    return [3, 2, 0, -1, 0, 2, 4, 5, 4, 2]
            case .treble:    return [0, 0, 0, 0, 0, 1, 3, 4, 5, 6]
            case .night:     return [-6, -4, -1, 1, 2, 2, 1, -1, -3, -4]
            }
        }
    }

    public var isEnabled = true
    public let sampleRate: Double

    private let bandCount = Equalizer.bandCount
    private let targetGains: UnsafeMutablePointer<Float>
    private let activeGains: UnsafeMutablePointer<Float>
    /// 5 coefficients per band: b0, b1, b2, a1, a2
    private let coeffs: UnsafeMutablePointer<Float>
    /// 4 state values per band per channel (x1, x2, y1, y2) for stereo = 8 floats/band
    private let states: UnsafeMutablePointer<Float>
    private var anyActive = false

    public init(sampleRate: Double) {
        self.sampleRate = max(sampleRate, 1)
        targetGains = .allocate(capacity: bandCount)
        targetGains.initialize(repeating: 0, count: bandCount)
        activeGains = .allocate(capacity: bandCount)
        activeGains.initialize(repeating: 0, count: bandCount)
        coeffs = .allocate(capacity: bandCount * 5)
        coeffs.initialize(repeating: 0, count: bandCount * 5)
        states = .allocate(capacity: bandCount * 8)
        states.initialize(repeating: 0, count: bandCount * 8)
        for band in 0..<bandCount {
            updateCoefficients(band: band, gainDB: 0)
        }
    }

    deinit {
        targetGains.deallocate()
        activeGains.deallocate()
        coeffs.deallocate()
        states.deallocate()
    }

    public var bands: [Float] {
        (0..<bandCount).map { targetGains[$0] }
    }

    public func setBand(_ index: Int, gainDB: Float) {
        guard index >= 0, index < bandCount else { return }
        targetGains[index] = min(max(gainDB, Self.minGainDB), Self.maxGainDB)
    }

    public func setBands(_ gains: [Float]) {
        for index in 0..<min(gains.count, bandCount) {
            setBand(index, gainDB: gains[index])
        }
    }

    public func apply(preset: Preset) {
        setBands(preset.gainsDB)
    }

    public func resetState() {
        states.initialize(repeating: 0, count: bandCount * 8)
    }

    /// Processes interleaved stereo frames in place. Allocation-free and lock-free.
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard isEnabled, frames > 0 else { return }

        var active = false
        for band in 0..<bandCount {
            let desired = targetGains[band]
            if desired != activeGains[band] {
                activeGains[band] = desired
                updateCoefficients(band: band, gainDB: desired)
            }
            if abs(activeGains[band]) > 0.05 {
                active = true
            }
        }
        anyActive = active
        guard active else { return }

        for band in 0..<bandCount {
            guard abs(activeGains[band]) > 0.05 else { continue }
            let cBase = band * 5
            let b0 = coeffs[cBase]
            let b1 = coeffs[cBase + 1]
            let b2 = coeffs[cBase + 2]
            let a1 = coeffs[cBase + 3]
            let a2 = coeffs[cBase + 4]

            let sBase = band * 8
            var lx1 = states[sBase]
            var lx2 = states[sBase + 1]
            var ly1 = states[sBase + 2]
            var ly2 = states[sBase + 3]
            var rx1 = states[sBase + 4]
            var rx2 = states[sBase + 5]
            var ry1 = states[sBase + 6]
            var ry2 = states[sBase + 7]

            for frame in 0..<frames {
                let idx = frame * 2
                let lx0 = samples[idx]
                let ly0 = b0 * lx0 + b1 * lx1 + b2 * lx2 - a1 * ly1 - a2 * ly2
                lx2 = lx1; lx1 = lx0
                ly2 = ly1; ly1 = ly0
                samples[idx] = ly0

                let rx0 = samples[idx + 1]
                let ry0 = b0 * rx0 + b1 * rx1 + b2 * rx2 - a1 * ry1 - a2 * ry2
                rx2 = rx1; rx1 = rx0
                ry2 = ry1; ry1 = ry0
                samples[idx + 1] = ry0
            }

            states[sBase] = lx1
            states[sBase + 1] = lx2
            states[sBase + 2] = ly1
            states[sBase + 3] = ly2
            states[sBase + 4] = rx1
            states[sBase + 5] = rx2
            states[sBase + 6] = ry1
            states[sBase + 7] = ry2
        }
    }

    private func updateCoefficients(band: Int, gainDB: Float) {
        let cBase = band * 5
        let freq = Self.frequencies[band]
        // Clamp frequency safely below Nyquist.
        if abs(gainDB) <= 0.05 || freq >= sampleRate * 0.45 {
            coeffs[cBase] = 1
            coeffs[cBase + 1] = 0
            coeffs[cBase + 2] = 0
            coeffs[cBase + 3] = 0
            coeffs[cBase + 4] = 0
            return
        }

        let a = pow(10.0, Double(gainDB) / 40.0)
        let w0 = 2.0 * Double.pi * freq / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let q = 1.41
        let alpha = sinW0 / (2.0 * q)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosW0
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha / a

        let invA0 = 1.0 / a0
        coeffs[cBase] = Float(b0 * invA0)
        coeffs[cBase + 1] = Float(b1 * invA0)
        coeffs[cBase + 2] = Float(b2 * invA0)
        coeffs[cBase + 3] = Float(a1 * invA0)
        coeffs[cBase + 4] = Float(a2 * invA0)
    }
}
