/// Error when an operation is requested, but the client/handle is already closed
public struct AlreadyClosed: Error {
}

/// Error when an operation is requested before being logged in
public struct NotLoggedIn: Error {
}
