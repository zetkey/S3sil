import Foundation
import Testing
@testable import S3SilKit

private func creds(_ accessKey: String, _ secret: String = "secret") -> S3Credentials {
    S3Credentials(accessKeyID: accessKey, secretAccessKey: secret)
}

@Test("The consolidated item uses a single all-profiles account")
func consolidatedAccountShape() {
    #expect(KeychainStore.consolidatedAccount == "all-profiles")
}

@Test("Merge adds new stray keys into an empty dictionary")
func mergeAddsNewKeys() throws {
    let uuid1 = try #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))
    let uuid2 = try #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002"))

    let merged = KeychainStore.merge(
        existing: [:],
        strays: [
            (profileID: uuid1.uuidString, credentials: creds("key-1")),
            (profileID: uuid2.uuidString, credentials: creds("key-2"))
        ]
    )

    #expect(merged.count == 2)
    #expect(merged[uuid1.uuidString] == creds("key-1"))
    #expect(merged[uuid2.uuidString] == creds("key-2"))
}

@Test("Merge keeps the consolidated value when a stray collides")
func mergePrefersExistingOnCollision() throws {
    let uuid1 = try #require(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001"))

    let merged = KeychainStore.merge(
        existing: [uuid1.uuidString: creds("OLD", "old-secret")],
        strays: [(profileID: uuid1.uuidString, credentials: creds("NEW", "new-secret"))]
    )

    #expect(merged.count == 1)
    #expect(merged[uuid1.uuidString] == creds("OLD", "old-secret"))
}

@Test("Merge ignores malformed and non-UUID accounts")
func mergeIgnoresNonUUIDAccounts() {
    let merged = KeychainStore.merge(
        existing: [:],
        strays: [
            (profileID: "all-profiles", credentials: creds("x")),
            (profileID: "not-a-uuid", credentials: creds("y")),
            (profileID: "", credentials: creds("z"))
        ]
    )

    #expect(merged.isEmpty)
}

@Test("Merge mixes valid, colliding, and malformed accounts correctly")
func mergeMixedAccounts() throws {
    let uuid1 = try #require(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001"))
    let uuid2 = try #require(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002"))

    let merged = KeychainStore.merge(
        existing: [uuid1.uuidString: creds("existing")],
        strays: [
            (profileID: uuid1.uuidString, credentials: creds("collision")),
            (profileID: uuid2.uuidString, credentials: creds("fresh")),
            (profileID: "garbage", credentials: creds("ignored"))
        ]
    )

    #expect(merged.count == 2)
    #expect(merged[uuid1.uuidString] == creds("existing"))
    #expect(merged[uuid2.uuidString] == creds("fresh"))
    #expect(merged["garbage"] == nil)
}