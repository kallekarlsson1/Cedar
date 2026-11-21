import Foundation

/// One bit per dimension (is the value positive?): 128 bytes per passage instead of 2,048. Close vectors agree on
/// most bits, so counting differing bits finds the likely matches fast; those few are then scored exactly.
public enum Bits {
    public static let words = EmbeddingModel.dimension / 64

    public static func code(_ v: UnsafeBufferPointer<Float16>) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: words)
        for i in 0..<v.count where v[i] > 0 { out[i >> 6] |= 1 << UInt64(i & 63) }
        return out
    }

    public static func code(_ v: [Float]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: words)
        for i in 0..<v.count where v[i] > 0 { out[i >> 6] |= 1 << UInt64(i & 63) }
        return out
    }

    /// The `keep` rows whose codes differ least from the query's.
    public static func nearest(_ query: [UInt64], in codes: [UInt64], rows: Int, keep: Int) -> [Int] {
        var distance = [UInt16](repeating: 0, count: rows)
        codes.withUnsafeBufferPointer { c in
            query.withUnsafeBufferPointer { q in
                DispatchQueue.concurrentPerform(iterations: 8) { part in
                    let from = rows * part / 8, to = rows * (part + 1) / 8
                    for r in from..<to {
                        var d = 0
                        let base = r * words
                        for w in 0..<words { d += (c[base + w] ^ q[w]).nonzeroBitCount }
                        distance[r] = UInt16(d)
                    }
                }
            }
        }
        // Counting sort over the 0...1024 possible distances: no full sort of a million rows.
        var counts = [Int](repeating: 0, count: EmbeddingModel.dimension + 2)
        for d in distance { counts[Int(d)] += 1 }
        var cutoff = 0, taken = 0
        while cutoff <= EmbeddingModel.dimension, taken + counts[cutoff] < keep { taken += counts[cutoff]; cutoff += 1 }
        var out: [Int] = []
        out.reserveCapacity(keep + counts[min(cutoff, EmbeddingModel.dimension)])
        for r in 0..<rows where Int(distance[r]) <= cutoff { out.append(r) }
        return out
    }
}
