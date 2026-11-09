import Foundation

/// The cached bytes of one file: sorted runs that neither overlap nor touch, plus the ranges written through the client
/// since the file's last stat.
struct FileBlocks {
    /// A run of contiguous cached bytes.
    struct Segment: Equatable {
        /// Position of the first byte in the file.
        var start: UInt64

        /// The bytes, indexed from zero.
        var bytes: Data

        /// Position just past the last byte.
        var end: UInt64 {
            start + UInt64(bytes.count)
        }
    }

    /// The runs, sorted by position. Two runs never overlap or touch.
    private(set) var segments: [Segment] = []

    /// Total bytes held.
    private(set) var byteCount = 0

    /// Ranges written through the client since the file's last stat, sorted and merged.
    private(set) var uploaded: [Range<UInt64>] = []

    var isEmpty: Bool {
        segments.isEmpty
    }

    /// The cached ranges, sorted.
    var ranges: [Range<UInt64>] {
        segments.map { $0.start ..< $0.end }
    }

    // MARK: Reading

    /// Whether a run holds the byte at `offset`.
    func contains(_ offset: UInt64) -> Bool {
        segmentIndex(containing: offset) != nil
    }

    /// A copy of the cached bytes starting exactly at `offset`, at most `upTo` of them and none at or past `end`.
    ///
    /// - Returns: The bytes, or `nil` when no run holds the byte at `offset`.
    func run(at offset: UInt64, upTo: Int, end: UInt64?) -> Data? {
        guard upTo > 0, let index = segmentIndex(containing: offset) else {
            return nil
        }

        let segment = segments[index]
        let stop = min(segment.end, end ?? .max)
        guard stop > offset else {
            return nil
        }

        let count = Int(min(UInt64(upTo), stop - offset))
        return copy(of: segment, from: offset, count: count)
    }

    /// Up to `count` ranges of at most `length` bytes, chosen at random among the cached bytes, with their contents.
    func randomSamples(count: Int, length: Int) -> [(offset: UInt64, bytes: Data)] {
        guard byteCount > 0, count > 0, length > 0 else {
            return []
        }

        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in
            // Each segment is chosen in proportion to its size, then a window within it.
            var position = Int.random(in: 0 ..< byteCount, using: &generator)
            var chosen = segments[0]
            for segment in segments {
                if position < segment.bytes.count {
                    chosen = segment
                    break
                }
                position -= segment.bytes.count
            }

            let window = min(length, chosen.bytes.count)
            let latestStart = chosen.bytes.count - window
            let start = latestStart == 0 ? 0 : Int.random(in: 0 ... latestStart, using: &generator)
            let offset = chosen.start + UInt64(start)
            return (offset, copy(of: chosen, from: offset, count: window))
        }
    }

    // MARK: Writing

    /// Stores `data` at `offset`, over any bytes already cached there.
    ///
    /// - Parameter isUpload: Whether the bytes were written through the client. Downloaded bytes stop counting as
    /// written since the last stat.
    mutating func write(_ data: Data, at offset: UInt64, isUpload: Bool) {
        guard !data.isEmpty else {
            return
        }

        let end = offset + UInt64(data.count)
        if isUpload {
            uploaded = Self.union(uploaded, offset ..< end)
        }
        else {
            uploaded = Self.subtracting(offset ..< end, from: uploaded)
        }

        // Overwriting bytes inside one run: replace them in place. No local copy of the run may hold its storage
        // meanwhile, or replacing would copy all of it.
        if let index = segmentIndex(containing: offset), end <= segments[index].end {
            let from = segments[index].bytes.startIndex + Int(offset - segments[index].start)
            segments[index].bytes.replaceSubrange(from ..< from + data.count, with: data)
            return
        }

        // Every run that overlaps or touches the new bytes merges with them into one.
        let low = firstSegmentIndex(endingAtOrAfter: offset)
        var high = low
        while high < segments.count, segments[high].start <= end {
            high += 1
        }

        guard low < high else {
            segments.insert(Segment(start: offset, bytes: Self.copy(data)), at: low)
            byteCount += data.count
            return
        }

        let removed = segments[low ..< high].reduce(0) { $0 + $1.bytes.count }
        let start = min(segments[low].start, offset)

        // The bytes of the last run past the new ones. When the first run also holds them, the new bytes fall inside it
        // and were replaced in place above.
        let lastEnd = segments[high - 1].end
        let tail: Data? = if lastEnd > end {
            Self.copy(segments[high - 1].bytes.suffix(Int(lastEnd - end)))
        }
        else {
            nil
        }

        var merged: Data
        if segments[low].start < offset {
            // Take the first run's storage over, so appending does not copy it.
            let kept = Int(offset - segments[low].start)
            merged = Data()
            swap(&merged, &segments[low].bytes)
            merged.removeSubrange(merged.startIndex + kept ..< merged.endIndex)
            merged.append(data)
        }
        else {
            merged = Self.copy(data)
        }

        if let tail {
            merged.append(tail)
        }

        segments.replaceSubrange(low ..< high, with: [Segment(start: start, bytes: merged)])
        byteCount += merged.count - removed
    }

    /// Drops every byte not written through the client since the last stat, and starts counting writes afresh.
    mutating func keepOnlyUploaded() {
        var kept: [Segment] = []
        for range in uploaded {
            for segment in segments where segment.start < range.upperBound && segment.end > range.lowerBound {
                let from = max(segment.start, range.lowerBound)
                let to = min(segment.end, range.upperBound)
                kept.append(Segment(start: from, bytes: copy(of: segment, from: from, count: Int(to - from))))
            }
        }

        // Written ranges are merged, so the kept runs neither overlap nor touch.
        segments = kept
        byteCount = kept.reduce(0) { $0 + $1.bytes.count }
        uploaded = []
    }

    /// Starts counting writes afresh, keeping every byte.
    mutating func forgetUploads() {
        uploaded = []
    }

    /// Drops every byte at or past `size`.
    mutating func truncate(to size: UInt64) {
        while let index = segments.indices.last, segments[index].end > size {
            let count = segments[index].bytes.count
            if segments[index].start >= size {
                segments.removeLast()
                byteCount -= count
            }
            else {
                let kept = Int(size - segments[index].start)
                let from = segments[index].bytes.startIndex + kept
                segments[index].bytes.removeSubrange(from ..< from + (count - kept))
                byteCount -= count - kept
            }
        }

        uploaded = Self.subtracting(size ..< .max, from: uploaded)
    }

    /// Drops every byte.
    mutating func removeAll() {
        segments = []
        byteCount = 0
        uploaded = []
    }

    // MARK: Private

    /// Index of the run holding the byte at `offset`.
    private func segmentIndex(containing offset: UInt64) -> Int? {
        let index = firstSegmentIndex(endingAtOrAfter: offset)
        guard index < segments.count, segments[index].start <= offset, segments[index].end > offset else {
            return nil
        }
        return index
    }

    /// Index of the first run that ends at or after `offset`, or the number of runs.
    private func firstSegmentIndex(endingAtOrAfter offset: UInt64) -> Int {
        var low = 0
        var high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].end < offset {
                low = middle + 1
            }
            else {
                high = middle
            }
        }
        return low
    }

    /// A copy of `count` bytes of `segment` starting at file position `offset`, in storage of its own.
    private func copy(of segment: Segment, from offset: UInt64, count: Int) -> Data {
        let from = segment.bytes.startIndex + Int(offset - segment.start)
        return Self.copy(segment.bytes[from ..< from + count])
    }

    /// `data` in storage of its own, indexed from zero, so it neither pins a larger buffer nor shares one that later
    /// changes.
    private static func copy(_ data: Data) -> Data {
        data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { Data(bytes: $0, count: buffer.count) } ?? Data()
        }
    }

    /// `ranges` with `range` added, sorted and merged.
    static func union(_ ranges: [Range<UInt64>], _ range: Range<UInt64>) -> [Range<UInt64>] {
        var lower = range.lowerBound
        var upper = range.upperBound
        var result: [Range<UInt64>] = []
        var inserted = false
        for existing in ranges {
            if existing.upperBound < lower {
                result.append(existing)
            }
            else if existing.lowerBound > upper {
                if !inserted {
                    result.append(lower ..< upper)
                    inserted = true
                }
                result.append(existing)
            }
            else {
                lower = min(lower, existing.lowerBound)
                upper = max(upper, existing.upperBound)
            }
        }
        if !inserted {
            result.append(lower ..< upper)
        }
        return result
    }

    /// `ranges` without `range`.
    static func subtracting(_ range: Range<UInt64>, from ranges: [Range<UInt64>]) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        for existing in ranges {
            guard existing.overlaps(range) else {
                result.append(existing)
                continue
            }
            if existing.lowerBound < range.lowerBound {
                result.append(existing.lowerBound ..< range.lowerBound)
            }
            if existing.upperBound > range.upperBound {
                result.append(range.upperBound ..< existing.upperBound)
            }
        }
        return result
    }
}
