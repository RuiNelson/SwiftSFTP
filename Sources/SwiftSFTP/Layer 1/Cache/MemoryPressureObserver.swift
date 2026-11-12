#if canImport(Darwin)
    import Dispatch

    /// Reports the system's memory pressure warnings, for as long as it lives.
    final class MemoryPressureObserver: @unchecked Sendable {
        private let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )

        init() {
            // Active from the start: an inactive source must not be released.
            source.activate()
        }

        /// Calls `handler` on every warning, with whether memory is critical. Call it once.
        func start(_ handler: @escaping @Sendable (_ critical: Bool) -> Void) {
            source.setEventHandler { [weak self] in
                guard let self else {
                    return
                }
                handler(source.data.contains(.critical))
            }
        }

        deinit {
            source.cancel()
        }
    }
#endif
