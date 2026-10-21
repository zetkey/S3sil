# S3Sil

S3Sil is a native macOS S3 browser for Apple Silicon. It implements AWS Signature Version 4 directly (Swift, SwiftUI, CryptoKit — no third-party dependencies, no web views, no telemetry) and works with AWS S3, Cloudflare R2, Hitachi HCP/Vantara S3, MinIO, and generic S3-compatible endpoints such as Backblaze B2, Wasabi, DigitalOcean Spaces, Linode, Scaleway, Ceph, and Garage.

## Features

- **Bucket lifecycle:** create with provider-aware validation and bodies; delete empty buckets.
- **Bucket ACLs:** canned ACL editor where ACLs are effective. R2 has no ACL UI; MinIO is read-only because its ACL APIs are emulated; runtime-disabled ACLs (403/501, `AccessControlListNotSupported`, Bucket-Owner-Enforced) degrade the editor with an explanation instead of a false success.
- **Multipart upload:** files of 64 MiB or more upload in 16 MiB parts, scaled so a file never exceeds 10,000 parts; four parts in flight; failure or cancel aborts the upload.
- **Drag-out download:** drag selected rows to Finder or any file-promise consumer, single or multi-selection, with progress and cancel.
- **Drag-in upload:** drop files from Finder onto the object table, or use the file importer.
- **Presigned URLs:** 15 minutes to 7 days, copyable from the object menu and inspector.
- **Inspector and transfer queue:** object metadata with a live presigned URL; aggregate progress with per-item cancel and retry, up to three concurrent transfers.

## Requirements

- macOS 14.0 or later
- Apple Silicon (arm64)
- Swift 5.10 or later
- Xcode 15+ or Command Line Tools with the macOS 14+ SDK

## Build and run

```bash
swift build
swift test
swift build -c release --arch arm64
scripts/make-app.sh   # assembles build/S3Sil.app, ad-hoc signed, with the app icon copied into the bundle
open build/S3Sil.app
```

For development without a bundle, `swift run S3Sil` works; the app bundle is preferred because its `Info.plist` (including the ATS settings) applies to `URLSession` requests.

## Connections

Click **Add Connection** in the sidebar or press Command-N. Every profile has an editable name, endpoint, region, and a path-style/virtual-hosted toggle.

| Provider | Configuration |
| --- | --- |
| AWS S3 | Region required; empty endpoint becomes `s3.<region>.amazonaws.com`. Virtual-hosted by default. |
| Cloudflare R2 | Enter the Cloudflare account ID; endpoint becomes `https://<account-id>.r2.cloudflarestorage.com`. Region `auto`, path-style, no ACL APIs. |
| Hitachi HCP / Vantara S3 | S3 gateway endpoint; path-style and `us-east-1` by default. |
| MinIO | Endpoint including scheme and port for LAN installs, e.g. `http://127.0.0.1:9000`; path-style and `us-east-1` by default. |
| S3-Compatible | All fields editable; path-style by default. |

Endpoints without a scheme default to `https://`, except MinIO (`http://`). A base path in the endpoint is supported. Buckets with dotted names automatically use path-style addressing for transport, signing, and presigned URLs, because TLS wildcard certificates do not match dotted hostnames.

**Test Connection** runs a signed `ListBuckets` request and reports the result inside the editor.

## Notes

- Credentials (access key, secret key, optional session token) are stored only in the macOS Keychain, one generic-password item per profile; `profiles.json` under `~/Library/Application Support/S3Sil/` holds metadata only and is created with mode `0600`.
- The app bundle sets `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true` so LAN MinIO and other HTTP endpoints work; the app is not sandboxed.
- Security: no credentials are ever written to logs, crash messages, or the repository; smoke/test credentials come from environment variables only. Endpoints default to HTTPS — use HTTP only on a trusted local network. The app sends no telemetry.

## Usage

- The sidebar lists connections and buckets; selecting a bucket opens the object browser with breadcrumb navigation, prefix search, and sortable columns.
- **Upload** opens a file importer, or drag files in from Finder. Files ≥ 64 MiB upload via multipart automatically.
- Drag selected file rows out to Finder to download them; progress and cancel are in the transfers panel.
- **Create Bucket** / **Delete Bucket…** live in the sidebar and bucket context menus; deletion only succeeds when the bucket is empty.
- **Access Control…** opens the canned bucket ACL sheet where the provider supports it (see Features).
- **New Folder** writes a zero-byte folder marker; **Delete** removes selected objects, recursing into folders in batches of 1000.
- **Copy Presigned URL** offers 15 minutes, 1 hour, 24 hours, or 7 days.
- The inspector shows key, size, modified date, ETag, storage class, and a live presigned URL; the transfers panel shows per-item progress, cancel, retry, and reveal in Finder.

Shortcuts: Command-N new connection, Command-U upload, Command-D download, Shift-Command-N new folder, Command-Delete delete, Command-R refresh, Option-Command-I inspector, Option-Command-T transfers.

## Testing

```bash
swift test
```

Current result: **45 tests in 2 suites, all passing** (Swift Testing), covering the official AWS SigV4 test vectors, presigned URLs, endpoint resolution, S3 XML parsing, listing dedupe, multipart sizing, provider ACL gating, and profile storage.

An end-to-end smoke run against a local MinIO exercises bucket create/delete, object upload (including a multipart round-trip with byte-for-byte comparison), listings with pagination, presigned downloads, and batched deletes:

```bash
MINIO_ENDPOINT=http://127.0.0.1:9000 \
MINIO_ACCESS_KEY=... \
MINIO_SECRET_KEY=... \
MINIO_REGION=us-east-1 \
./scripts/smoke-minio.sh
```

## Known limitations

- Object ACLs, grant-by-grant editing, bucket policies, versioning, and object lock are not exposed — bucket lifecycle and canned bucket ACLs only.
- MinIO bucket ACLs are read-only (emulated APIs); R2 has no ACL UI at all.
- Delete bucket requires an empty bucket.
- The app is ad-hoc signed, so macOS may re-prompt for Keychain access after a rebuild; a Developer ID certificate avoids this.
- Drag-out locates SwiftUI `Table`'s backing `NSTableView` and may need revisiting if macOS internals change ([`docs/drag-drop-research.md`](docs/drag-drop-research.md)).
- ACL behavior has been exercised against MinIO only; the AWS, R2, and Hitachi ACL paths are covered by unit tests and runtime error handling, not live endpoint tests.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/S3SilKit` | Provider models, SigV4, endpoint resolution, XML parsing, async `S3Client`, Keychain and profile storage. |
| `Sources/S3Sil` | The SwiftUI app: views, state, transfer manager, commands. |
| `Sources/S3SilSmoke` | End-to-end smoke harness (`scripts/smoke-minio.sh`). |
| `Tests/S3SilKitTests` | Swift Testing suite with SigV4 fixtures. |
| `docs/` | Provider reference, behavior notes, SigV4 sources and test vectors. |

## Documentation

- [`docs/providers.md`](docs/providers.md) — provider reference: defaults, addressing, regions, cited sources.
- [`docs/acl-multipart.md`](docs/acl-multipart.md) — bucket ACL behavior by provider and multipart upload reference.
- [`docs/listing-behavior.md`](docs/listing-behavior.md) — folder markers, `CommonPrefixes`, and HCP/B2 ghost-parent parsing.
- [`docs/drag-drop-research.md`](docs/drag-drop-research.md) — file promises, the drag overlay, and SwiftUI `Table` internals.
- [`docs/sigv4-sources.md`](docs/sigv4-sources.md) — authoritative SigV4 references and test-vector provenance.
- [`docs/sigv4-suite/`](docs/sigv4-suite/) — upstream AWS SigV4 test-suite vectors with their `LICENSE` and `NOTICE`.

## License

S3Sil is licensed under the [Apache License, Version 2.0](LICENSE). The upstream AWS SigV4 test-suite vectors under [`docs/sigv4-suite/`](docs/sigv4-suite/) retain their own [`LICENSE`](docs/sigv4-suite/LICENSE) and [`NOTICE`](docs/sigv4-suite/NOTICE).
