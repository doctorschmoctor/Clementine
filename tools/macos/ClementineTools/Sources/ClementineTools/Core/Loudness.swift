// Loudness as broadcasters measure it (ITU-R BS.1770 / EBU R128): integrated loudness, loudness range and true peak,
// and the processing that brings a recording to a target: a slow leveler for the range, gain, and a lookahead limiter.

import Foundation

struct LoudnessStats: Equatable {
    var integrated: Double   // LUFS
    var range: Double        // LU
    var truePeak: Double     // dBTP

    static func format(_ v: Double, _ unit: String) -> String { v.isFinite ? String(format: "%.1f %@", v, unit) : "–" }
}

enum Loudness {
    /// The K-weighted signal power summed over channels, as prefix sums (so any window's mean is two lookups).
    private static func weightedPrefix(_ audio: AudioData) -> [Double] {
        let fs = audio.sampleRate
        // Stage 1: high shelf.
        var K = tan(Double.pi * 1681.974450955533 / fs)
        let Vh = pow(10, 3.999843853973347 / 20), Vb = pow(Vh, 0.4996667741545416), Q1 = 0.7071752369554196
        var a0 = 1 + K / Q1 + K * K
        let s1b = [(Vh + Vb * K / Q1 + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q1 + K * K) / a0]
        let s1a = [2 * (K * K - 1) / a0, (1 - K / Q1 + K * K) / a0]
        // Stage 2: high pass.
        K = tan(Double.pi * 38.13547087602444 / fs)
        let Q2 = 0.5003270373238773
        a0 = 1 + K / Q2 + K * K
        let s2a = [2 * (K * K - 1) / a0, (1 - K / Q2 + K * K) / a0]

        let n = audio.frameCount
        var prefix = [Double](repeating: 0, count: n + 1)
        var power = [Double](repeating: 0, count: n)
        for channel in audio.channels {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, z1 = 0.0, z2 = 0.0, w1 = 0.0, w2 = 0.0
            for i in 0..<n {
                let x = Double(channel[i])
                let y = s1b[0] * x + s1b[1] * x1 + s1b[2] * x2 - s1a[0] * y1 - s1a[1] * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                let z = y - 2 * z1 + z2 - s2a[0] * w1 - s2a[1] * w2
                z2 = z1; z1 = y; w2 = w1; w1 = z
                power[i] += z * z
            }
        }
        for i in 0..<n { prefix[i + 1] = prefix[i] + power[i] }
        return prefix
    }

    private static func loudness(_ meanPower: Double) -> Double { -0.691 + 10 * log10(max(meanPower, 1e-12)) }

    /// Mean power of windows of <window> seconds every <hop> seconds; (start time, power).
    private static func windows(_ prefix: [Double], fs: Double, window: Double, hop: Double) -> [(Double, Double)] {
        let n = prefix.count - 1
        let w = Int(window * fs), h = max(1, Int(hop * fs))
        guard n >= w, w > 0 else { return n > 0 ? [(0, prefix[n] / Double(n))] : [] }
        var result: [(Double, Double)] = []
        var start = 0
        while start <= n - w {
            let sum: Double = prefix[start + w] - prefix[start]
            result.append((Double(start) / fs, sum / Double(w)))
            start += h
        }
        return result
    }

    static func measure(_ audio: AudioData) -> LoudnessStats {
        guard audio.frameCount > 0 else { return LoudnessStats(integrated: -.infinity, range: 0, truePeak: -.infinity) }
        let prefix = weightedPrefix(audio)
        let fs = audio.sampleRate

        // Integrated: 400 ms blocks every 100 ms, gated at −70 LUFS and 10 LU below their mean.
        let blocks = windows(prefix, fs: fs, window: 0.4, hop: 0.1).map(\.1).filter { loudness($0) > -70 }
        var integrated = -Double.infinity
        if !blocks.isEmpty {
            let relative = loudness(blocks.reduce(0, +) / Double(blocks.count)) - 10
            let gated = blocks.filter { loudness($0) > relative }
            if !gated.isEmpty { integrated = loudness(gated.reduce(0, +) / Double(gated.count)) }
        }

        // Range: 3 s windows, gated at −70 and 20 LU below their mean, 95th minus 10th percentile.
        let short = windows(prefix, fs: fs, window: 3, hop: 0.1).map(\.1).filter { loudness($0) > -70 }
        var range = 0.0
        if short.count > 1 {
            let relative = loudness(short.reduce(0, +) / Double(short.count)) - 20
            let levels = short.map(loudness).filter { $0 > relative }.sorted()
            if levels.count > 1 {
                let p10 = levels[Int(Double(levels.count - 1) * 0.10)]
                let p95 = levels[Int(Double(levels.count - 1) * 0.95)]
                range = p95 - p10
            }
        }
        return LoudnessStats(integrated: integrated, range: range, truePeak: truePeak(audio))
    }

    /// Peak between samples too: 4× oversampled with cubic interpolation.
    static func truePeak(_ audio: AudioData) -> Double {
        var peak: Float = 0
        for c in audio.channels where c.count > 3 {
            for i in 1..<(c.count - 2) {
                let p0 = c[i - 1], p1 = c[i], p2 = c[i + 1], p3 = c[i + 2]
                peak = max(peak, abs(p1))
                for k in 1...3 {
                    let t = Float(k) / 4
                    let c1: Float = p2 - p0
                    let c2: Float = 2 * p0 - 5 * p1 + 4 * p2 - p3
                    let c3: Float = 3 * (p1 - p2) + p3 - p0
                    let v: Float = 0.5 * (2 * p1 + c1 * t + c2 * t * t + c3 * t * t * t)
                    peak = max(peak, abs(v))
                }
            }
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    struct Settings: Equatable {
        var target = -14.0
        var limitRange = false
        var maxRange = 8.0
        var ceiling = -1.0
    }

    /// Brings <audio> to the target loudness: when the limiter took loudness away, aims higher and tries again.
    static func normalize(_ audio: AudioData, settings: Settings, input: LoudnessStats) -> (AudioData, LoudnessStats) {
        var aim = settings
        var out = process(audio, settings: aim, input: input)
        var stats = measure(out)
        for _ in 0..<3 where stats.integrated.isFinite && abs(stats.integrated - settings.target) > 0.2 {
            aim.target += settings.target - stats.integrated
            out = process(audio, settings: aim, input: input)
            stats = measure(out)
        }
        return (out, stats)
    }

    /// Brings <audio> to the target loudness, optionally narrowing its range, never past the true-peak ceiling.
    static func process(_ audio: AudioData, settings: Settings, input: LoudnessStats) -> AudioData {
        var out = audio
        let fs = audio.sampleRate
        let n = audio.frameCount
        guard n > 0, input.integrated.isFinite else { return audio }

        // 1. Leveler: pull 3 s loudness towards the integrated level so the range fits.
        if settings.limitRange, input.range > settings.maxRange, input.range > 0 {
            let ratio = max(0.15, settings.maxRange / input.range)
            let prefix = weightedPrefix(audio)
            let hop = 0.1
            let points = windows(prefix, fs: fs, window: 3, hop: hop).map { (t, p) -> (Double, Double) in
                let level = loudness(p)
                let gain = level > -70 ? (input.integrated + (level - input.integrated) * ratio) - level : 0
                return (t + 1.5, min(12, max(-24, gain)))
            }
            if !points.isEmpty {
                var j = 0
                for i in 0..<n {
                    let t = Double(i) / fs
                    while j + 1 < points.count && points[j + 1].0 <= t { j += 1 }
                    let g: Double
                    if t <= points[0].0 { g = points[0].1 }
                    else if j + 1 >= points.count { g = points[points.count - 1].1 }
                    else {
                        let (t0, g0) = points[j], (t1, g1) = points[j + 1]
                        g = g0 + (g1 - g0) * (t - t0) / (t1 - t0)
                    }
                    let lin = Float(pow(10, g / 20))
                    for c in 0..<out.channels.count { out.channels[c][i] *= lin }
                }
            }
        }

        // 2. Gain to the target.
        let current = settings.limitRange ? measure(out).integrated : input.integrated
        let gain = Float(pow(10, (settings.target - current) / 20))
        for c in 0..<out.channels.count {
            for i in 0..<n { out.channels[c][i] *= gain }
        }

        // 3. Lookahead limiter to the ceiling (a little under it: the true peak sits between samples).
        let ceiling = Float(pow(10, (settings.ceiling - 0.3) / 20))
        let lookahead = max(1, Int(0.005 * fs))
        var required = [Float](repeating: 1, count: n)
        for i in 0..<n {
            var peak: Float = 0
            for c in out.channels { peak = max(peak, abs(c[i])) }
            if peak > ceiling { required[i] = ceiling / peak }
        }
        guard required.contains(where: { $0 < 1 }) else { return out }
        // Gain reaches each peak's level <lookahead> samples early, falls in a ramp, and recovers over 80 ms.
        var gainCurve = required
        var i = n - 2
        let ramp = 1 / Float(lookahead)
        while i >= 0 { gainCurve[i] = min(gainCurve[i], gainCurve[i + 1] + ramp); i -= 1 }
        let release = Float(1 - exp(-1 / (0.08 * fs)))
        var g: Float = 1
        for k in 0..<n {
            g = min(gainCurve[k], g + (1 - g) * release)
            for c in 0..<out.channels.count { out.channels[c][k] *= g }
        }
        return out
    }
}
