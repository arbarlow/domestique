import Testing
@testable import ServerKit

@Test func generatedTypesLoad() { #expect(Proto_Hello().protocolVersion == .unspecified) }
