import Foundation

/// How an ``SFTPSwarmProtocol`` looks after its connections.
public struct SwarmOptions: Sendable {
    /// How a broken connection is replaced: `tries` forks of a working client, `delay` seconds apart. The first try
    /// starts as soon as the connection breaks. Zero tries leaves broken connections unreplaced.
    public var replaceBrokenConnections: (tries: Int, delay: TimeInterval)

    /// - Parameter replaceBrokenConnections: `tries` must not be negative and `delay` must be finite and not negative.
    /// Other values stop the process.
    public init(replaceBrokenConnections: (tries: Int, delay: TimeInterval) = (tries: 1, delay: 0)) {
        precondition(replaceBrokenConnections.tries >= 0, "tries must not be negative")
        precondition(
            replaceBrokenConnections.delay.isFinite && replaceBrokenConnections.delay >= 0,
            "delay must be finite and not negative"
        )
        self.replaceBrokenConnections = replaceBrokenConnections
    }

    /// One try, with no delay.
    public static let `default` = SwarmOptions()
}

/// A set of SFTP connections to one server, used as one client.
///
/// A swarm keeps its connections open for its whole life. Each operation goes to a connection no other operation is
/// using, and waits, first come first served, while every connection is busy. Uploads and downloads of files larger
/// than ``smallFileThreshold`` are split into stripes, each sent to the next free connection, so one transfer uses
/// every connection and a short operation waits for one stripe at most, not for a whole transfer. Smaller files move in
/// place over one connection, as with ``SFTPClient``.
///
/// Operations started concurrently run in no particular order, as on separate clients: renaming a file while deleting
/// it does whatever the server does with the two. Operations awaited one after the other run in that order.
///
/// A file handle from ``SFTPClientProtocol/openFile(_:path:permissions:)`` stays on the connection it was opened on,
/// without reserving it: other operations still go to that connection between the handle's own calls.
///
/// A connection that fails with a network or session error is taken out of the swarm and replaced as
/// ``SwarmOptions/replaceBrokenConnections`` says. The operation that hit it throws that error; stripes of a transfer
/// are sent again on another connection instead. File handles on a broken connection keep failing until closed.
public protocol SFTPSwarmProtocol: SFTPClientProtocol {
    /// Creates a swarm of `client` and `numberOfForksToCreate` forks of it.
    ///
    /// The swarm owns `client` from now on and closes it with the others. Forks that fail to log in are retried as
    /// `options` says. When one still fails, the forks already made are closed, `client` stays yours and open, and the
    /// error is thrown.
    ///
    /// - Parameters:
    ///   - client: A logged-in client. Using it after ``SFTPClientProtocol/close()`` is a ``MisuseError``. A swarm
    /// cannot hold another swarm.
    ///   - numberOfForksToCreate: How many connections to add to `client`. A negative value stops the process.
    ///   - options: How broken connections are replaced.
    init(_ client: any SFTPClientProtocol, numberOfForksToCreate: Int, options: SwarmOptions) async throws

    /// Creates a swarm of `clients`, which it owns from now on.
    ///
    /// - Parameters:
    ///   - clients: Logged-in clients of the same server, each once. An empty list, a repeated client, or a swarm stops
    /// the process; a closed client is a ``MisuseError``.
    ///   - options: How broken connections are replaced.
    init(_ clients: [any SFTPClientProtocol], options: SwarmOptions) async throws

    /// The largest file, in bytes, that uploads and downloads move in place over one connection, as ``SFTPClient``
    /// does. Defaults to 10 MiB.
    ///
    /// A larger file is split into stripes of ``stripeSize`` bytes, sent in order to whichever connection is free, into
    /// a temporary file beside the destination that carries a trailer recording how much of the payload has arrived.
    /// The temporary file is renamed onto the destination once complete, and an interrupted transfer leaves it behind
    /// for the next one to continue. Zero stripes every non-empty file.
    var smallFileThreshold: FileSize { get set }

    /// Bytes per stripe of a transfer larger than ``smallFileThreshold``: the unit one connection moves at a time, and
    /// the granularity of resuming. Defaults to 8 MiB. Values below one stop the process.
    var stripeSize: Int { get set }

    /// The connections that take work now, and the number the swarm keeps.
    ///
    /// `healthy` is lower than `setNumber` while a broken connection waits for its replacement, and after every
    /// replacement attempt failed. ``increaseClients(_:)`` adds connections on top of `setNumber`.
    func clientCount() async -> (healthy: Int, setNumber: Int)

    /// Adds `count` connections, forked from a working one.
    ///
    /// Forks that fail to log in are retried as ``SwarmOptions/replaceBrokenConnections`` says. The connections that
    /// could be made are kept; when some could not, the last error is thrown and `setNumber` grows only by the ones
    /// that were.
    ///
    /// - Parameter count: A positive number. Other values stop the process.
    func increaseClients(_ count: Int) async throws

    /// Removes `count` connections, the least busy first.
    ///
    /// Idle connections close before this returns. A connection still running an operation, or holding open file
    /// handles, takes no new work and closes once it is free.
    ///
    /// - Parameter count: A positive number that leaves at least one connection. Other values stop the process.
    func decreaseClients(_ count: Int) async throws

    /// Finds the number of connections that uploads `localFile` fastest, leaves the swarm at it, and returns every
    /// measurement.
    ///
    /// Each round uploads `localFile` to `testFilePath`, always in stripes of ``stripeSize`` whatever
    /// ``smallFileThreshold`` says, and deletes it. Starting at the current number of connections:
    ///
    /// 0. Measure the starting point.
    /// 1. Measure one connection more. While that is faster, keep adding one.
    /// 2. When one more is not faster, measure the previous number again, to see whether its first result was a fluke.
    /// When it was, and one more is faster after all, continue from there.
    ///
    /// Each repeated measurement of step 2 is a back and forth, and there are at most `maximumBackAndForths` of them.
    ///
    /// Other operations running meanwhile share the connections and skew the measurements. Use a file of at least
    /// `clientCountLimit` stripes, ideally several times that, or there is not enough work to share.
    ///
    /// - Parameters:
    ///   - localFile: The file to upload in every round.
    ///   - testFilePath: A remote path that must not exist yet. Missing parent directories are created and left.
    ///   - clientCountLimit: The most connections to try. Must be positive.
    ///   - maximumBackAndForths: How many fluke checks to make at most. Must not be negative.
    /// - Returns: Bytes per second by number of connections, the last measurement of each.
    /// - Throws: ``FileTransferErrors/remoteFileAlreadyExists(path:)`` when `testFilePath` exists, and the errors of
    /// the uploads.
    func autoTuneForUpload(
        localFile: URL,
        testFilePath: String,
        clientCountLimit: Int,
        maximumBackAndForths: Int
    ) async throws -> [Int: Double]

    /// Finds the number of connections that downloads `testFilePath` fastest, leaves the swarm at it, and returns every
    /// measurement.
    ///
    /// The same search as
    /// ``autoTuneForUpload(localFile:testFilePath:clientCountLimit:maximumBackAndForths:)``, downloading to a local
    /// temporary file in every round.
    ///
    /// - Parameters:
    ///   - testFilePath: The remote file to download in every round.
    ///   - createTestFileIfDoesNotExist: When `create` is `true` and `testFilePath` does not exist, a file of `size`
    /// random bytes is uploaded there first and deleted at the end.
    ///   - clientCountLimit: The most connections to try. Must be positive.
    ///   - maximumBackAndForths: How many fluke checks to make at most. Must not be negative.
    /// - Returns: Bytes per second by number of connections, the last measurement of each.
    /// - Throws: ``FileTransferErrors/remoteFileNotFound(path:)`` when `testFilePath` is missing and may not be
    /// created, and the errors of the transfers.
    func autoTuneForDownload(
        testFilePath: String,
        createTestFileIfDoesNotExist: (create: Bool, size: FileSize),
        clientCountLimit: Int,
        maximumBackAndForths: Int
    ) async throws -> [Int: Double]
}
