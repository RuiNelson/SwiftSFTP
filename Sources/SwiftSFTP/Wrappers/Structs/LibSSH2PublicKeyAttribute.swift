import libssh2

public struct LibSSH2PublicKeyAttribute: Sendable, Equatable {
    public var name: String
    public var value: String
    public var isMandatory: Bool

    public init(name: String, value: String, isMandatory: Bool) {
        self.name = name
        self.value = value
        self.isMandatory = isMandatory
    }

    public init(_ rawValue: libssh2_publickey_attribute) {
        self.name = String(cString: rawValue.name)
        self.value = String(cString: rawValue.value)
        self.isMandatory = rawValue.mandatory != 0
    }
}
