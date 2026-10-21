import Foundation
import Testing
@testable import S3SilKit

@Suite("Drag export helpers")
struct DragExportTests {
    @Test func safeFileNameKeepsSpacesAndUnicode() {
        #expect(DragExport.safeFileName("Quarterly report – naïve.txt") == "Quarterly report – naïve.txt")
        #expect(DragExport.safeFileName("archive.tar.gz") == "archive.tar.gz")
    }

    @Test func safeFileNameStripsPathAndColon() {
        #expect(DragExport.safeFileName("folder/data:2026.bin") == "data-2026.bin")
        #expect(DragExport.safeFileName("a/b/c.png") == "c.png")
    }

    @Test func safeFileNameFallsBackWhenEmpty() {
        #expect(DragExport.safeFileName("") == "download")
        #expect(DragExport.safeFileName("..") == "download")
        #expect(DragExport.safeFileName("   ") == "download")
    }

    @Test func fileObjectsFiltersFoldersAndHonorsSelection() {
        let objects = [
            S3Object(key: "a/", name: "a", kind: .folder),
            S3Object(key: "a/one.txt", name: "one.txt", kind: .file),
            S3Object(key: "a/two.bin", name: "two.bin", kind: .file)
        ]
        let selected = DragExport.fileObjects(in: objects, selectedKeys: ["a/", "a/two.bin"])
        #expect(selected.map(\.key) == ["a/two.bin"])
        #expect(DragExport.fileObjects(in: objects, selectedKeys: []).isEmpty)
    }
}
