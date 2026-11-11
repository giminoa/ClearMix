import Foundation

/// Downward expander / noise gate with hysteresis and hold.
///
/// RNNoise handles steady noise (fans, hum) well but lets sharp transients
/// through, so the mic chain closes the gate below a speech threshold instead.
/// The gate ramps its gain so opening and closing stay click-free.
public final class NoiseGate {
    private let sampleRate: Double

    private var openThreshold: Float
    private var closeThreshold: Float
    private var floorGain: Float
    private let holdFrames: Int
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let detectorRelease: Float

    private var envelope: Float = 0
    private var currentGain: Float = 0
    private var holdRemaining: Int = 0

    public private(set) var isOpen = false

    /// Enables or disables gating without losing the configured thresholds.
    public var isEnabled = true {
        didSet {
            if !isEnabled {
                holdRemaining = 0
            }
        }
    }

    /// Level in dBFS that opens the gate.
    public var thresholdDB: Float = -45 {
        didSet { updateThresholds() }
    }

    /// Additional level below the threshold that closes the gate again.
    public var hysteresisDB: Float = 3 {
        didSet { updateThresholds() }
    }

    /// Gain applied while the gate is closed. -60 dB is effectively silence.
    public var floorDB: Float = -60 {
        didSet { floorGain = AudioMath.dbToLinear(floorDB) }
    }

    public init(
        sampleRate: Double,
        attackMilliseconds: Double = 5,
        holdMilliseconds: Double = 120,
        releaseMilliseconds: Double = 140
    ) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.sampleRate = sampleRate
        attackCoefficient = AudioMath.smoothingCoefficient(
            milliseconds: attackMilliseconds,
            sampleRate: sampleRate
        )
        releaseCoefficient = AudioMath.smoothingCoefficient(
            milliseconds: releaseMilliseconds,
            sampleRate: sampleRate
        )
        detectorRelease = AudioMath.smoothingCoefficient(
            milliseconds: 50,
            sampleRate: sampleRate
        )
        holdFrames = max(0, Int(holdMilliseconds * 0.001 * sampleRate))
        openThreshold = AudioMath.dbToLinear(-45)
        closeThreshold = AudioMath.dbToLinear(-48)
        floorGain = AudioMath.dbToLinear(-60)
    }

    /// Current gate gain, 0...1. Useful for the UI indicator.
    public var gain: Float { currentGain }

    public func reset() {
        envelope = 0
        currentGain = 0
        holdRemaining = 0
        isOpen = false
    }

    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }

        let open = openThreshold
        let close = closeThreshold
        let floor = floorGain
        let hold = holdFrames
        let attack = attackCoefficient
        let release = releaseCoefficient
        let decay = detectorRelease
        let enabled = isEnabled

        var env = envelope
        var gain = currentGain
        var holdLeft = holdRemaining
        var openNow = isOpen

        for index in 0..<frames {
            let sample = samples[index]
            let magnitude = abs(sample)

            // Peak detector: instant attack, exponential release.
            env = magnitude > env ? magnitude : env * decay

            if openNow {
                if env < close {
                    if holdLeft > 0 {
                        holdLeft -= 1
                    } else {
                        openNow = false
                    }
                } else {
                    holdLeft = hold
                }
            } else if env >= open {
                openNow = true
                holdLeft = hold
            }

            let target: Float = (!enabled || openNow) ? 1 : floor
            let coefficient = target > gain ? attack : release
            gain = target + (gain - target) * coefficient

            samples[index] = sample * gain
        }

        envelope = env
        currentGain = gain
        holdRemaining = holdLeft
        isOpen = openNow
    }

    private func updateThresholds() {
        openThreshold = AudioMath.dbToLinear(thresholdDB)
        closeThreshold = AudioMath.dbToLinear(thresholdDB - hysteresisDB)
    }
}
