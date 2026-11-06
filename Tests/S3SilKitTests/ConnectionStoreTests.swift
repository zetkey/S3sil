import Foundation
import Testing
@testable import S3SilKit

@Test("Old profile JSON (no new fields) decodes successfully")
func backwardCompatDecode() throws {
    let json = """
    [{"id":"AABBCCDD-EEFF-1122-3344-556677889900","name":"Test","provider":"aws","endpoint":"","region":"us-east-1","accountID":"","pathStyle":false}]
    """
    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    let profiles = try decoder.decode([ConnectionProfile].self, from: data)
    #expect(profiles.count == 1)
    let p = try #require(profiles.first)
    #expect(p.name == "Test")
    #expect(p.provider == .aws)
    #expect(p.host == "")
    #expect(p.port == nil)
    #expect(p.basePath == "")
    #expect(p.useTLS == false)
    #expect(p.privateKeyPath == nil)
}

@Test("Profiles round-trip without credentials in JSON")
func profileStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStore(directory: directory)
    let profiles = [
        ConnectionProfile(name: "AWS", provider: .aws, region: "us-east-1"),
        ConnectionProfile(name: "MinIO", provider: .minio, endpoint: "http://127.0.0.1:9000",
                          region: "us-east-1"),
        ConnectionProfile(name: "R2", provider: .cloudflareR2, accountID: "abc123")
    ]

    try store.save(profiles)
    let loaded = try store.load()
    #expect(loaded == profiles)

    let json = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(json.contains("MinIO"))
    #expect(!json.contains("secret"))
    #expect(!json.contains("accessKey"))
    let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test("Missing profile file reads as empty")
func missingStore() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStore(directory: directory)
    #expect(try store.load().isEmpty)
}

@Test("Unreadable profile file is backed up instead of overwritten")
func corruptStoreBackup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStore(directory: directory)
    try Data("not json".utf8).write(to: store.fileURL)

    #expect(throws: ConnectionStoreError.self) { try store.load() }
    let backup = try store.backUpCorruptedFile()
    let backupURL = try #require(backup)
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
}
