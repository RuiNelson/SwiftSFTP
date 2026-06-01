import Foundation
import libssh2

public struct LibSSH2PublicKeyListEntry: Sendable, Codable, Equatable {
    public let name: Data
    public let blob: Data
    public let attributes: [LibSSH2PublicKeyAttribute]

    public init(name: Data, blob: Data, attributes: [LibSSH2PublicKeyAttribute]) {
        self.name = name
        self.blob = blob
        self.attributes = attributes
    }

    public init(_ rawValue: libssh2_publickey_list) {
        self.name = rawValue.name.data(count: Int(rawValue.name_len))
        self.blob = rawValue.blob.data(count: Int(rawValue.blob_len))
        if let attrs = rawValue.attrs {
            self.attributes = (0..<Int(rawValue.num_attrs)).map { LibSSH2PublicKeyAttribute(attrs[$0]) }
        } else {
            self.attributes = []
        }
    }
}
