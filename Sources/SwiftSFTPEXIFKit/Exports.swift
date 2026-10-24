#if canImport(EXIFKit)
    // The SwiftSFTPEXIFKit product links EXIFKit into its dynamic library. Re-exporting it lets consumers use EXIFKit
    // without adding its product a second time, which would link a second copy.
    @_exported import EXIFKit
#endif
