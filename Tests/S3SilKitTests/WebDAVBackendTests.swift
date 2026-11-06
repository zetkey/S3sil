import Foundation
import Testing
@testable import S3SilKit

/// Covers Koofr WebDAV compatibility: folder detection for servers that omit
/// `<collection/>` and trailing slashes, and URL construction that preserves a
/// non-root base path (e.g. `https://app.koofr.net/dav/Koofr`).
struct WebDAVBackendTests {

    private func makeBackend(_ endpoint: String) throws -> WebDAVBackend {
        let profile = ConnectionProfile(
            name: "Test",
            provider: .webdav,
            endpoint: endpoint
        )
        return try WebDAVBackend(profile: profile, credentials: S3Credentials(accessKeyID: "u", secretAccessKey: "p"))
    }

    // MARK: - urlForKey

    @Test func urlForKeyPreservesBasePathAndSingleTrailingSlash() throws {
        let backend = try makeBackend("https://app.koofr.net/dav/Koofr")
        #expect(backend.urlForKey("") == URL(string: "https://app.koofr.net/dav/Koofr"))
        #expect(backend.urlForKey("hello.txt") == URL(string: "https://app.koofr.net/dav/Koofr/hello.txt"))
        #expect(backend.urlForKey("subdir/") == URL(string: "https://app.koofr.net/dav/Koofr/subdir/"))
        #expect(backend.urlForKey("a/b/") == URL(string: "https://app.koofr.net/dav/Koofr/a/b/"))
    }

    /// A non-root base path must not be dropped (regression: `relativeTo` resolved
    /// `subdir` against `/dav/Koofr` and produced `/dav/subdir`, losing `Koofr`).
    @Test func urlForKeyDoesNotDropBasePathComponent() throws {
        let backend = try makeBackend("https://example.com/dav/Mount/External Drive")
        #expect(backend.urlForKey("photos/").absoluteString.contains("External%20Drive/photos/"))
    }

    // MARK: - Folder detection

    @Test func koofrStyleFoldersAreDetected() throws {
        let backend = try makeBackend("http://localhost:8080")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/photos</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>0</D:getcontentlength>
                <D:resourcetype/>
                <D:getcontenttype>application/octet-stream</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/img001.jpg</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>1234</D:getcontentlength>
                <D:resourcetype/>
                <D:getcontenttype>image/jpeg</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """

        let entries = try backend.parsePropfind(Data(xml.utf8), relativeTo: backend.urlForKey(""))
        let resolved = backend.applyAmbiguousFolderHeuristic(entries)

        let folder = resolved.first { $0.name == "photos" }
        let file = resolved.first { $0.name == "img001.jpg" }
        #expect(folder?.isFolder == true)
        #expect(folder?.key == "photos/")
        #expect(file?.isFolder == false)
    }

    @Test func standardServerKeepsExtensionlessZeroByteFile() throws {
        let backend = try makeBackend("http://localhost:8080")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/subdir/</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>0</D:getcontentlength>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/Makefile</D:href>
            <D:propstat>
              <D:prop>
                <D:getcontentlength>0</D:getcontentlength>
                <D:resourcetype/>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """

        let entries = try backend.parsePropfind(Data(xml.utf8), relativeTo: backend.urlForKey(""))
        let resolved = backend.applyAmbiguousFolderHeuristic(entries)

        let subdir = resolved.first { $0.name == "subdir" }
        let makefile = resolved.first { $0.name == "Makefile" }
        #expect(subdir?.isFolder == true)
        // Server already exposes folders via <collection/>, so the 0-byte
        // extension-less file must NOT be reclassified as a folder.
        #expect(makefile?.isFolder == false)
    }
}