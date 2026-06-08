import Foundation

public extension SFTPClientProtocol {
    func setAttributes(
        path: String,
        size: Int64? = nil,
        owner: (uid: Int, gid: Int)? = nil,
        date: (modification: Date, access: Date)? = nil,
        permissions: POSIXPermissions? = nil
    ) async throws {
        guard size != nil || owner != nil || date != nil || permissions != nil else {
            return
        }

        var attrs = FileAttributes()
        guard attrs.apply(size: size, owner: owner, date: date, permissions: permissions) else {
            return
        }

        try await setAttributes(path: path, attributes: attrs)
    }
}
