#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import SwiftSFTP
    import UniformTypeIdentifiers

    /// Answers AVFoundation requests on one delegate queue, without letting serving tasks retain the loader.
    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        let queue: DispatchQueue
        let contentType: UTType

        private let server: RequestServer
        private let lock = NSLock()
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

        convenience init(client: any SFTPClientProtocol, path: String, contentType: UTType) {
            self.init(
                source: MediaSource { try await client.openFile(.read, path: path, permissions: []) },
                contentType: contentType
            )
        }

        init(source: MediaSource, contentType: UTType) {
            let queue = DispatchQueue(label: "com.ruinelson.SwiftSFTP.MediaResourceLoader")
            self.queue = queue
            self.contentType = contentType
            server = RequestServer(
                source: source,
                contentType: contentType,
                queue: queue
            )
        }

        var servingRequestCount: Int {
            lock.withLock { tasks.count }
        }

        deinit {
            for task in tasks.values {
                task.cancel()
            }
            let source = server.source
            Task { await source.close() }
        }

        func resourceLoader(
            _: AVAssetResourceLoader,
            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
        ) -> Bool {
            let request = LoadingRequest(value: loadingRequest)
            let range = loadingRequest.dataRequest.map(RequestedRange.init)
            let id = ObjectIdentifier(loadingRequest)
            let server = server
            // Register the task before it can remove itself. It retains the server, while referencing the loader
            // weakly.
            lock.withLock {
                tasks[id] = Task { [weak self] in
                    await server.serve(request, range: range)
                    self?.removeTask(id)
                }
            }
            return true
        }

        func resourceLoader(_: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
            removeTask(ObjectIdentifier(loadingRequest))?.cancel()
        }

        @discardableResult
        private func removeTask(_ id: ObjectIdentifier) -> Task<Void, Never>? {
            lock.withLock { tasks.removeValue(forKey: id) }
        }
    }

    @available(macOS 11, iOS 14, tvOS 14, macCatalyst 14, visionOS 1, *)
    private struct RequestServer: Sendable {
        let source: MediaSource
        let contentType: UTType
        let queue: DispatchQueue

        func serve(_ request: LoadingRequest, range: RequestedRange?) async {
            do {
                let size = try await source.size()
                let contentType = contentType
                guard await onQueue(request, { loadingRequest in
                    if let info = loadingRequest.contentInformationRequest {
                        info.contentType = contentType.identifier
                        info.contentLength = size
                        info.isByteRangeAccessSupported = true
                    }
                }) else { return }

                if let range {
                    var offset = min(max(0, range.start), size)
                    let end = range.toEnd ? size : min(range.end, size)
                    while offset < end {
                        try Task.checkCancellation()
                        let data = try await source.read(
                            upTo: Int(min(64 * 1024, end - offset)),
                            atOffset: UInt64(offset)
                        )
                        guard let data, !data.isEmpty else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                        }
                        guard await onQueue(request, { $0.dataRequest?.respond(with: data) }) else { return }
                        offset += Int64(data.count)
                    }
                }

                await onQueue(request) { $0.finishLoading() }
            }
            catch is CancellationError {
                // A cancelled or released asset must not receive a completion for this request.
            }
            catch {
                let failure = MediaLoadingError.make(error)
                await onQueue(request) { $0.finishLoading(with: failure) }
            }
        }

        /// Waits for delivery before fetching more bytes, keeping buffering bounded even on a busy delegate queue.
        @discardableResult
        private func onQueue(
            _ request: LoadingRequest,
            _ body: @escaping @Sendable (AVAssetResourceLoadingRequest) -> Void
        ) async -> Bool {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                queue.async {
                    let loadingRequest = request.value
                    guard !loadingRequest.isCancelled, !loadingRequest.isFinished else {
                        continuation.resume(returning: false)
                        return
                    }
                    body(loadingRequest)
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Snapshots the data request on its delegate queue.
    private struct RequestedRange: Sendable {
        let start: Int64
        let end: Int64
        let toEnd: Bool

        init(_ dataRequest: AVAssetResourceLoadingDataRequest) {
            start = dataRequest.currentOffset
            let (end, overflow) = dataRequest.requestedOffset
                .addingReportingOverflow(Int64(dataRequest.requestedLength))
            self.end = overflow ? .max : end
            toEnd = dataRequest.requestsAllDataToEndOfResource
        }
    }

    /// Only accesses the wrapped request on its delegate queue.
    private struct LoadingRequest: @unchecked Sendable {
        let value: AVAssetResourceLoadingRequest
    }
#endif
