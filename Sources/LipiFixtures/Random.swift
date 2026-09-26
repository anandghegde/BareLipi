/// Deterministic generator (Vigna's SplitMix64) so every fixture is the same
/// on every machine and every run.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `0..<n`.
    public mutating func below(_ n: Int) -> Int {
        Int(next() % UInt64(max(1, n)))
    }

    public mutating func chance(_ p: Double) -> Bool {
        Double(next() >> 11) / Double(1 << 53) < p
    }

    public mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }
}
