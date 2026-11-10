@testable import SwiftSFTP
import Foundation
import Testing

/// Randomized runs of ``CacheSimulation``: a simulated client and server around a real cache and a real registry of
/// open files, with everything the cache answers checked against what the server holds.
///
/// The first four tests keep apart the orderings the tests under "Harder cases" each let in, one kind at a time: those
/// are orderings the real client can produce, in which what the cache is told, when it is told it, or what the registry
/// of open files makes of it leaves the cache answering wrongly. `ReferenceCacheRaceIntegrationTests` reproduces each
/// of them with the real client on the test server.
///
/// A failure names its seeds and lists the steps that led to the first. `SWIFTSFTP_CACHE_FUZZ_SEED=<seed>` runs that
/// seed alone, `SWIFTSFTP_CACHE_FUZZ_LOG_LINES=<n>` lists that many of its last steps, and
/// `SWIFTSFTP_CACHE_FUZZ_SCALE=<n>` runs `n` times as many seeds: the rarer orderings take thousands of runs to turn
/// up, so a test that passes with the few seeds it runs by default says little until it passes a larger run.
@Suite("ReferenceCache: simulated client and server")
struct ReferenceCacheSimulationTests {
    /// A configuration drawn from `seed`, with budgets and limits small enough for eviction and refusals to happen
    /// within a few hundred steps.
    static func configuration(seed: UInt64, answersMetadata: Bool) -> ReferenceCache.Configuration {
        var generator = SeededGenerator(seed: seed ^ 0xC0FFEE)
        let budgets = [0, 96, 300, 1 << 20, 1 << 20]
        let fileSizes: [UInt64?] = [nil, nil, 60, 1000]
        let hitLengths = [0, 0, 1, 16, 64 * 1024]

        return .init(
            byteBudget: generator.pick(budgets),
            maximumFileSize: generator.pick(fileSizes),
            keepsUploads: generator.chance(0.7),
            minimumHitLength: generator.pick(hitLengths),
            trustPolicy: .trustReports,
            metadata: answersMetadata ? .answer(for: 3600, includingMissing: generator.chance(0.5)) : .neverAnswer
        )
    }

    /// The options the simulation of `seed` starts from. Every other seed is crowded: two places a file can be, so that
    /// operations in flight together are mostly about the same file.
    ///
    /// - Parameter concurrent: Whether two to four operations are in flight together, rather than one.
    static func options(seed: UInt64, answersMetadata: Bool, concurrent: Bool) -> CacheSimulation.Options {
        .init(
            configuration: configuration(seed: seed, answersMetadata: answersMetadata),
            concurrency: concurrent ? 2 + Int(seed / 2 % 3) : 1,
            crowded: seed % 2 == 1
        )
    }

    /// Runs one simulation per seed, and fails with the first that found something wrong, naming the others.
    ///
    /// - Returns: How many lookups the cache answered with bytes, and how many reads there were.
    @discardableResult
    static func simulate(
        _ seeds: [UInt64],
        sourceLocation: SourceLocation = #_sourceLocation,
        _ options: @escaping @Sendable (UInt64) -> CacheSimulation.Options
    ) async -> (hits: Int, reads: Int) {
        var failures: [(seed: UInt64, failure: String)] = []
        var hits = 0
        var reads = 0

        await withTaskGroup(of: (UInt64, String?, Int, Int).self) { group in
            for seed in seeds {
                group.addTask {
                    let simulation = CacheSimulation(seed: seed, options: options(seed))
                    await simulation.run()
                    return (seed, simulation.failure, simulation.hits, simulation.reads)
                }
            }

            for await (seed, failure, seedHits, seedReads) in group {
                hits += seedHits
                reads += seedReads
                if let failure {
                    failures.append((seed, failure))
                }
            }
        }

        failures.sort { $0.seed < $1.seed }
        if let first = failures.first {
            Issue.record(
                """
                \(failures.count) of \(seeds.count) seeds found the cache wrong: \(failures.map(\.seed)). The first:
                \(first.failure)
                """,
                sourceLocation: sourceLocation
            )
        }
        return (hits, reads)
    }

    // MARK: What the cache must get right

    @Test("one operation at a time: every answer is what the server holds")
    func sequential() async {
        let result = await Self.simulate(CacheFuzz.seeds(100)) { seed in
            Self.options(seed: seed, answersMetadata: false, concurrent: false)
        }

        // A cache that never answers passes every check.
        #expect(result.hits > result.reads / 20, "the cache answered \(result.hits) of \(result.reads) reads")
    }

    @Test("one operation at a time, with stats and listings answered from the cache")
    func sequentialWithMetadataAnswers() async {
        await Self.simulate(CacheFuzz.seeds(100)) { seed in
            Self.options(seed: seed, answersMetadata: true, concurrent: false)
        }
    }

    @Test("operations in flight together: no answer is older than the oldest change still in flight")
    func concurrent() async {
        let result = await Self.simulate(CacheFuzz.seeds(250)) { seed in
            Self.options(seed: seed, answersMetadata: false, concurrent: true)
        }
        #expect(result.hits > result.reads / 20, "the cache answered \(result.hits) of \(result.reads) reads")
    }

    @Test("operations in flight together, with stats and listings answered from the cache")
    func concurrentWithMetadataAnswers() async {
        await Self.simulate(CacheFuzz.seeds(250)) { seed in
            Self.options(seed: seed, answersMetadata: true, concurrent: true)
        }
    }

    // MARK: Harder cases

    @Test("answered directory stats and listings show the modification time the directory has")
    func directoryModificationTimes() async {
        await Self.simulate(CacheFuzz.seeds(30)) { seed in
            var options = Self.options(seed: seed, answersMetadata: true, concurrent: false)
            options.checksDirectoryTimes = true
            return options
        }
    }

    @Test("a report of an open file that a change overlapped is not answered from before the client invalidates it")
    func overlappedReports() async {
        await Self.simulate(CacheFuzz.seeds(300)) { seed in
            var options = Self.options(seed: seed, answersMetadata: seed % 4 < 2, concurrent: true)
            options.exposesOverlappedReports = true
            return options
        }
    }

    @Test("a file that closes while it is being renamed leaves nothing behind at the path it had")
    func closesDuringRenames() async {
        await Self.simulate(CacheFuzz.seeds(300)) { seed in
            var options = Self.options(seed: seed, answersMetadata: true, concurrent: true)
            options.closesDuringRenames = true
            return options
        }
    }

    @Test("changes that race each other for the same bytes or paths still leave the cache showing the server")
    func racingChanges() async {
        await Self.simulate(CacheFuzz.seeds(60)) { seed in
            var options = Self.options(seed: seed, answersMetadata: false, concurrent: true)
            options.racesChanges = true
            return options
        }
    }

    @Test("a file opened just as its path is renamed over or deleted does not report as what took its place")
    func racingOpens() async {
        await Self.simulate(CacheFuzz.seeds(80)) { seed in
            var options = Self.options(seed: seed, answersMetadata: false, concurrent: true)
            options.racesOpens = true
            return options
        }
    }

    @Test("a read whose lookup waits behind other calls is still answered with bytes of the file it has open")
    func delayedLookups() async {
        await Self.simulate(CacheFuzz.seeds(700)) { seed in
            var options = Self.options(seed: seed, answersMetadata: false, concurrent: true)
            options.splitsReadLookups = true
            options.crowded = true
            return options
        }
    }

    @Test("bytes a read had asked for ahead, before a change, are not kept when they arrive after it")
    func readAhead() async {
        await Self.simulate(CacheFuzz.seeds(200)) { seed in
            var options = Self.options(seed: seed, answersMetadata: false, concurrent: true)
            options.readsAhead = true
            return options
        }
    }

    @Test("writes through a file that stopped reporting, while a path still leads to it, do not go unnoticed")
    func writesThroughSilencedHandles() async {
        await Self.simulate(CacheFuzz.seeds(100)) { seed in
            var options = Self.options(seed: seed, answersMetadata: false, concurrent: true)
            options.writesThroughSilencedHandles = true
            return options
        }
    }
}
