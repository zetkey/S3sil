# S3 Listing Behavior: Folder Markers, CommonPrefixes, and the "Ghost Parent" Bug

Research for the folder-marker parsing fix. Bug: HCP and B2 show the parent folder as a
0-byte "file" after entering it; MinIO does not.

**Method.** AWS/MinIO/Garage behavior confirmed from official docs, vendor source, and a
live MinIO run. HCP's doc portal (FluidTopics) is JS-gated and could not be read
programmatically; HCP and B2 are unverified except where real-world reports are cited.
No HCP/B2 credentials are available in this environment, so **no live provider testing
was performed** for HCP or B2.

## 1. AWS S3 semantics (ground truth)

A folder in S3 is only a key prefix. A "folder marker" is an ordinary object whose key
ends in `/`, usually 0 bytes (e.g. `parent/`). Nothing in the API treats it specially;
delimiter grouping is pure key-string logic:

- With `delimiter=/`, each key whose remaining suffix after `Prefix` contains `/` is
  rolled up into one `CommonPrefixes` entry (`prefix` + first segment + `/`) and is **not
  returned in `Contents`** ("rolled-up keys are not returned elsewhere in the response").
  Sources: [ListObjectsV2 API](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html),
  [listing keys programmatically](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ListingKeysUsingAPIs.html).
- So the **parent marker (`Contents[].Key == request Prefix`) cannot appear in a
  delimited listing at all**: it has no character after the prefix, so it is not rolled
  up, and per AWS docs + SDK tests it is simply **absent** (neither `Contents` nor
  `CommonPrefixes`). It exists only in recursive listings.
  Source: [SeaweedFS S3 empty-directory test](https://github.com/seaweedfs/seaweedfs/blob/12f28335/test/s3/normal/s3_list_empty_directory_test.go) —
  with `Prefix="Empty/", Delimiter="/"` the marker `Empty/empty/` (a *child* folder) is
  asserted in `CommonPrefixes` and *not* in `Contents`; recursively, the marker IS in
  `Contents`.
- Child folder markers (`Contents[].Key` ending in `/`, e.g. `parent/child/`): AWS
  **rolls them into `CommonPrefixes` and does not duplicate them in `Contents`** — a key
  appears in exactly one of the two lists. Empty folders therefore need a marker object
  (or console-created folder) to be visible in `CommonPrefixes` at all.
- Recursion (no delimiter): every marker is a regular `Contents` entry, `Size` 0.

`KeyCount` = number of `Contents` + `CommonPrefixes` entries (AWS doc). Directory-bucket
(S3 Express) quirks (trailing-slash-only prefixes, `/` as only delimiter) are out of
scope here.

## 2. Backblaze B2 (S3-compatible API)

- B2 native names may end in `/` (1024-byte UTF-8 cap; only control chars banned):
  [file names](https://www.backblaze.com/docs/cloud-storage-files#file-names). Clients
  create folder markers as 0-byte objects with trailing `/`; rclone adds
  `--b2-directory-markers` / `--s3-directory-markers` for empty dirs
  ([rclone #8071](https://github.com/rclone/rclone/issues/8071)).
- **[UNVERIFIED]** Delimited behavior: B2's S3 layer is believed to return the parent
  marker `Key == Prefix`, `Size 0` in `Contents` (the reported ghost), and child markers
  in `Contents` **and** `CommonPrefixes` (duplication). The only official S3 list doc is
  a v1 page ([S3 List Objects](https://www.backblaze.com/apidocs/s3-list-objects)) that
  does not document marker placement; no official statement found.
- **[UNVERIFIED]** A case-insensitive bucket-version quirk (keys sorting before the
  marker / lowercased CommonPrefixes on old buckets) is suspected from a related
  community report; not confirmed by official docs.

## 3. Hitachi Vantara HCP (Hitachi API for Amazon S3)

- **[CONFIRMED via real-world report]** HCP's S3 interface **implicitly creates 0-byte
  folder-marker objects for every path segment** when an object is stored under a
  folder-like prefix, and these markers surface in listings. Known since 2025 to break
  S3 clients: mlflow
  [#23284](https://github.com/mlflow/mlflow/issues/23284) shows `artifacts/`,
  `artifacts/llm_adapter/`, … as 0-byte entries; downloading one 404s on HCP. Fix:
  [mlflow#23250/#23324](https://github.com/mlflow/mlflow/pull/23324) skips
  0-byte trailing-slash objects.
- **[UNVERIFIED]** Delimited listing: parent marker (`Key == Prefix`) reportedly returned
  in `Contents` (the ghost); child markers may appear in both `Contents` and
  `CommonPrefixes`. Official docs say HCP S3 is modeled on the AWS API and folders are
  represented as 0-byte objects named with trailing `/`, but the doc portal is
  login-gated ([Folder structures](https://docs.hitachivantara.com/r/en-us/mk-95hcph002-18/using-the-hitachi-api-for-amazon-s3/usage-considerations/folder-structures)),
  so exact response shapes could not be confirmed.
- Tenant/namespace note: HCP namespaces are multi-protocol (NFS/SMB/HTTP/HS3 share one
  namespace). Markers created by one protocol can be visible via S3, and
  [deleting a "folder"](https://docs.hitachivantara.com/r/en-us/mk-95hcph002/latest/using-the-hitachi-api-for-amazon-s3/working-with-objects/deleting-an-object-or-folder)
  is document-gated as an object operation — treat markers as real objects, never
  special-case their deletion server-side.

## 4. MinIO (live-tested)

Confirmed by a live run
(`minio/minio:RELEASE.2024-01-16T16-07-38Z`, keys `parent/`, `parent/child/`,
`parent/leaf.txt`):

- `Prefix=parent/&Delimiter=/` → `Contents` = `parent/` **(0-byte marker, present!)**,
  `leaf.txt`; `CommonPrefixes` = `parent/child/`. **No duplication.**
- Recursive → `parent/`, `parent/child/`, `parent/leaf.txt` (markers included).
- `parent/` only exists if explicitly PUT (virtual prefixes alone never emit a
  `parent/` Content entry — MinIO does **not** synthesize one, matching AWS).

No official MinIO documentation describing marker placement in delimited listings was
found. Maintainer guidance in
[minio#10157](https://github.com/minio/minio/issues/10157): `CommonPrefixes` appears
when an empty directory exists and falls lexically in the returned batch. Known AWS
divergence: MinIO omits the root `/` prefix from `CommonPrefixes` where AWS returns it
([minio#21446](https://github.com/minio/minio/issues/21446), closed without code
change).

## 5. Other providers

- **Ceph RGW:** no official marker-duplication documentation found. Tracker has
  adjacent delimiter bugs ([#39989](https://tracker.ceph.com/issues/39989) start-marker +
  delimiter skips keys). Treat as conformant, verify defensively. **[UNVERIFIED]**
- **Garage:** conforms to AWS/MinIO semantics ("adhere as strictly as possible… to
  Minio or CEPH"); source emits each key in exactly one of `Contents`/`CommonPrefixes`
  ([list.rs](https://git.deuxfleurs.fr/kaiyou/garage/src/branch/docs-apps/src/api/s3/list.rs)).
  No marker quirks documented.
- **Wasabi:** no documented marker quirks found; marketed as AWS-API-identical.
  **[UNVERIFIED]**
- **DigitalOcean Spaces:** no documented marker quirks found (S3-compatible fork).
  **[UNVERIFIED]**
- **Cloudflare R2:** dashboard "Create folder" makes a 0-byte trailing-slash object;
  older releases miscalculated `KeyCount` with delimiters (since fixed). A ghost-file
  report exists ([community](https://community.cloudflare.com/t/r2-ghost-file-phenomenon/384894)),
  but no official duplication documentation. **[UNVERIFIED]**

## 6. Required parser invariants

1. **Parent-marker skip (the fix's core):** in a delimited listing
   (`Delimiter` was sent), drop any `Contents` entry whose `Key` equals the request
   `Prefix` exactly (typically `Size == 0`, trailing `/`). Never render it as a child.
2. **Trailing-slash `Contents` entries are folders:** any `Key` ending in `/` renders as
   a folder; never as a file. This alone fixes HCP/B2 recursive views.
3. **Dedupe against `CommonPrefixes`:** before appending a `Contents` entry, check its
   key (or `key + "/"`) against already-emitted CommonPrefixes; emit each path once,
   folder semantics winning.
4. **Preserve full recursive keys for deletion:** internal model keeps complete keys;
   deleting a folder issues prefix deletes **plus** an explicit delete of the exact
   marker key `folder/` (mlflow's HCP 404s show markers may not HEAD/GET like normal
   objects — tolerate missing-marker errors during cleanup).
5. Apply invariants 1–3 to every page of a paginated listing (markers may land on any
   page); count neither skipped parent markers nor deduped entries toward displayed
   child counts.
