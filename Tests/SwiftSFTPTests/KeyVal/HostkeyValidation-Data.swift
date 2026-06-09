enum HostkeyValidationTestData {
    static let testHost = "127.0.0.1"
    static let portHost = "[example.com]:2222"
    static let comment = "my-server"
    static let hashedLine = "|1|41FooCaPgKfMGes/o5XoPqbLDrA=|WnjepMwHMa5s7EpRtwlmZtOSKBU= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"

    enum RSA {
        static let shorthand = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsnF/As5B3bJeQwiYK+NEiAbMG8FWby5rqTEf4xyXU84IDp3Z/a4vbau7rYwOTyeEZUSHhG3hRxWyUMSKIrrzRn+CJF1t1q0FpRzeIaV0KLTQMkSzyFPqITMpaunagose2xF5+vaVSA/RcLxiUfXuIKNBMxshRaILFL4QOp5ochymEfXRg7aut2JOLXlpyeN8jgTykIf1A5D95WU6QvOg/iiPOwN1KWOFv1s8LLO91QJkFkb4OEB6jA5eSFZ+z1+MYmLuD+MdzqOAWXqZFm/32BybL2zVzICzRwB7yHMv0Y6So8OJMHsdpg/q81FG+9dxfEYZF3veXnjRnD5tBom4n"
        static let fullLine = "\(HostkeyValidationTestData.testHost) \(shorthand)"
        static let portLine = "\(HostkeyValidationTestData.portHost) \(shorthand)"
        static let lineWithComment = "\(HostkeyValidationTestData.testHost) \(shorthand) \(HostkeyValidationTestData.comment)"
    }

    enum P256 {
        static let shorthand = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBaaHV7bStEPE8tkquAhdyZJaw2Phxx95I7B6M2vnyhDFlrpOfw7TAh8HdJfSQ6mLs1dbwcPrja0Ut1BDiPRZD4="
        static let fullLine = "\(HostkeyValidationTestData.testHost) \(shorthand)"
        static let portLine = "\(HostkeyValidationTestData.portHost) \(shorthand)"
        static let lineWithComment = "\(HostkeyValidationTestData.testHost) \(shorthand) \(HostkeyValidationTestData.comment)"
    }

    enum P384 {
        static let shorthand = "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBEoNEcFvMp7xDAmiMyqx2kqJ98I6cxCI7Yj6IK0tJhlvCtec9wCzoPUGuCB81S5aVLdopJXTwW2wznpzBEwXolUaF6QqS6yJPeaEUFX6wjwQEDddiHkbIpgMKYPweJks6g=="
        static let fullLine = "\(HostkeyValidationTestData.testHost) \(shorthand)"
        static let portLine = "\(HostkeyValidationTestData.portHost) \(shorthand)"
        static let lineWithComment = "\(HostkeyValidationTestData.testHost) \(shorthand) \(HostkeyValidationTestData.comment)"
    }

    enum P521 {
        static let shorthand = "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBABzlO8ULYMmfBuDQvf0a7a6mD2W+s8YE7Evkn0WmLwyfBo2n2fACDsEyUEY+9TiPrkLZWPJjRYV1OUYub4EmBwhhAG3IbcfL6RsV18QPqSiH5HfR+sg6IAqjfQ9b4oi4yOYq+1TkhSK/p5hPUmuiK8U9sginypy9+hLizmkkcWALUdc9Q=="
        static let fullLine = "\(HostkeyValidationTestData.testHost) \(shorthand)"
        static let portLine = "\(HostkeyValidationTestData.portHost) \(shorthand)"
        static let lineWithComment = "\(HostkeyValidationTestData.testHost) \(shorthand) \(HostkeyValidationTestData.comment)"
    }

    enum Ed25519 {
        static let shorthand = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBQS8HuiXtRnfeKTpK+i1Gp7v2ekZBhsicnF95Bp3Zgq"
        static let fullLine = "\(HostkeyValidationTestData.testHost) \(shorthand)"
        static let portLine = "\(HostkeyValidationTestData.portHost) \(shorthand)"
        static let lineWithComment = "\(HostkeyValidationTestData.testHost) \(shorthand) \(HostkeyValidationTestData.comment)"
    }
}
