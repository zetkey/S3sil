# Bucket ACL & Multipart — Live MinIO Probe + Provider Reference

Date: 2026-10-20. Endpoint probed: `<provided-minio-endpoint>` (MinIO, path-style,
SigV4 region `us-east-1`). Credentials were passed only as `curl --aws-sigv4 … --user`
shell variables and are **not** recorded here. Companion doc: `docs/providers.md`
(endpoints/regions matrix). Object-level ACLs are **out of scope** for this feature —
everything below is bucket ACLs + multipart upload (MPU).

---

## 1. Live MinIO capability probe (curl `--aws-sigv4`)

All bodies below are abbreviated to the informative fields; statuses are exact.

| # | Request | Status | Body / notes |
|---|---------|--------|--------------|
| 1 | `GET /` (unsigned hello) | **403** | Server alive; rejects unsigned requests (expected). |
| 2 | `PUT /s3sil-probe-20261020-a1` (CreateBucket, **no body**) | **200** | Empty body. |
| 3 | `PUT /s3sil-probe-20261020-a1` again (duplicate) | **409** | `BucketAlreadyOwnedByYou`, "Your previous request to create the named bucket succeeded and you already own it." |
| 4 | `PUT /s3sil-probe-20261020-b2` **with** `<CreateBucketConfiguration><LocationConstraint>us-east-1</LocationConstraint></CreateBucketConfiguration>` body | **200** | LocationConstraint body is **accepted** (not rejected) alongside a region-less create. |
| 5 | `GET /` (ListBuckets) | **200** | `ListAllMyBucketsResult` with `Owner ID/DisplayName=minio` and bucket list incl. creations above. |
| 6 | `GET /<bucket>?acl` | **200** | Stub document (see below): empty `<Owner><ID></ID><DisplayName></DisplayName>`, one `<Grant>` with an empty `CanonicalUser` grantee and `FULL_CONTROL`. |
| 7 | `PUT /<bucket>?acl` + `x-amz-acl: private` | **200** | Empty body. Subsequent `GET ?acl` (#6 response) **unchanged** → silently ignored no-op. |
| 8 | `PUT /<bucket>?acl` + `x-amz-acl: public-read` | **501** | `<Error><Code>NotImplemented</Code><Message>A header you provided implies functionality that is not implemented ()</Message>…` |
| 9 | `POST /<bucket>/probe-mpu.bin?uploads` | **200** | `InitiateMultipartUploadResult` with opaque `UploadId` (base64 token). |
| 10 | `PUT …?partNumber=1&uploadId=…` and `partNumber=2` (2 × **5,242,880 B** = 5 MiB exact) | **200 / 200** | `ETag: "67b2dc35…"`, `ETag: "591ef7a1…"` (quoted, per part). |
| 11 | `GET …?uploadId=…` (ListParts) | **200** | Parts 1,2 @ `5242880` each. |
| 12 | `POST /<bucket>/probe-mpu.bin` **without** `?uploadId=` + Complete XML | **400** | `BadRequest` "An unsupported API call for method: POST …" — MinIO requires the `uploadId` query on Complete. |
| 13 | `POST /<bucket>/probe-mpu.bin?uploadId=…` + `<CompleteMultipartUpload>` (both ETags) | **200** | `CompleteMultipartUploadResult`, composite ETag `…"99b08644184c42ba19902015ec36e742-2"` (md5 + `-<nparts>`). |
| 14 | `HEAD` object | **200** | Present. `GET` full object = **10,485,760 B**, byte-compared against both local parts → **match**; range GET `0-15` → **206**, 16 bytes. |
| 15 | `POST /<bucket>/probe-abort.bin?uploads` (#2 upload), then `DELETE …?uploadId=…` | **200 / 204** | Abort is clean. Re-abort of the *same* uploadId → **204 again** (idempotent, no `NoSuchUpload`). `GET /<bucket>?uploads` afterwards → **zero** in-progress uploads. |
| 16 | `DELETE /<bucket-d4>` (empty except a **live in-progress MPU**, no parts uploaded) | **204** | Bucket gone (subsequent HEAD → 404); MPU discarded; not listed anymore. **MinIO does not block DeleteBucket on in-progress uploads.** |
| 17 | Cleanup: `DELETE` completed object, `DELETE` both probe buckets | **204** each | Re-delete → **404** (`NoSuchBucket`/`NoSuchKey`). Final ListBuckets grep for `s3sil-probe` → **0 matches**. Local temp part files removed. **Nothing left behind.** |

### 1.1 What this means for an ACL-capable UI

- **ACL reading is fake, writing is a no-op guard.** `GET ?acl` always returns the same
  hard-coded stub (owner blank, one anonymous `FULL_CONTROL` grant) regardless of any
  real state. `PUT ?acl` with `private` returns 200 but stores nothing; `public-read`
  (and any other canned ACL) → 501. Confirmed against MinIO source
  (`cmd/acl-handlers.go` @ `be7800c8`): `PutBucketACLHandler` is documented in-code as
  *"a dummy call … only responds success if the ACL is private"*, and
  `GetBucketACLHandler` *appends* a single `FULL_CONTROL` grant before encoding — there
  is no ACL storage anywhere. Both handlers authorize via
  `s3:GetBucketPolicy`/`s3:PutBucketPolicy` policy actions, not ACL actions.
- **Verdict for root MinIO credentials:** bucket ACLs are **not** actually supported —
  they are emulated just enough to keep AWS SDKs happy. A UI that reads the ACL will
  always display "FULL_CONTROL/private-ish" and writes to `private` will appear to
  succeed while changing nothing. **Do not present MinIO bucket ACLs as effective
  state.** Gate the ACL editor off for MinIO (offer bucket *policy* management
  instead, which is MinIO's real access-control surface).
- Detection heuristic that works without provider sniffing (matches the probe):
  `PUT ?acl x-amz-acl: public-read` → **501 ⇒ unsupported**; `GET ?acl` whose owner ID
  is empty + single FULL_CONTROL grant ⇒ stub, treat as unavailable.

---

## 2. Provider reference (official docs; `[UNVERIFIED]` where not confirmed)

### AWS S3

- **Bucket ACLs:** fully supported; canned ACLs for `PutBucketAcl` are
  `private | public-read | public-read-write | authenticated-read`
  (<https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketAcl.html>).
  Required IAM permissions: `s3:PutBucketAcl` (needs `WRITE_ACP` on the bucket) and
  `s3:GetBucketAcl` (needs `READ_ACP`) — same page + ACL overview
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/acl-overview.html>.
- **Object Ownership / ACLs disabled:** with `BucketOwnerEnforced` (ACLs disabled),
  "Requests to set ACLs or update ACLs fail and return the `AccessControlListNotSupported`
  error code. Requests to read ACLs are still supported."
  (<https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html>;
  error responses:
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-ownership-error-responses.html>).
  So on modern AWS buckets the expected outcome is: **PUT ACL fails, GET ACL works** —
  read-only display at best.
- Quirk: email-grantee ACLs discontinued 2025-10-01 → HTTP 405 in 9 regions (PutBucketAcl page).
- **Multipart:** min part **5 MiB** (last part exempt), max part **5 GiB**, max
  **10,000 parts**, max object **5 TiB**
  (<https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html>).
  Complete requires every part's ETag; Abort frees the parts.
- **DeleteBucket vs in-progress MPU:** documented hard block only for **directory
  buckets** ("if multipart uploads … are in progress, you can't delete the bucket until
  all the in-progress multipart uploads are aborted or completed",
  <https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteBucket.html>). For
  general-purpose buckets the same page requires only objects/versions/delete markers
  to be gone; the AWS procedure still instructs aborting in-progress MPUs before
  deleting (<https://repost.aws/knowledge-center/s3-delete-bucket>), and orphaned
  incomplete MPUs are **billed as storage** until aborted or lifecycle-expired
  (<https://aws.amazon.com/blogs/aws-cloud-financial-management/discovering-and-deleting-incomplete-multipart-uploads-to-lower-amazon-s3-costs/>).
  Treat "incomplete MPUs do not hard-block general-purpose DeleteBucket" as
  `[UNVERIFIED]` on the API page itself — the app must abort its own uploads on failure
  regardless (see §4).

### Cloudflare R2

- **Bucket ACLs: none.** `x-amz-acl`/grant headers unsupported; `GetBucketAcl` /
  `PutBucketAcl` not implemented (<https://developers.cloudflare.com/r2/api/s3/api/>).
  Public exposure is done via bucket policy / custom domains instead. **UI: never show
  an ACL editor for R2.**
- **Multipart:** part **5 MiB – 5 GiB**, max **10,000 parts**, max object **5 TiB**;
  max multipart total 4.995 TiB (5 GiB under the limit)
  (<https://developers.cloudflare.com/r2/objects/upload-objects/>,
  <https://developers.cloudflare.com/r2/platform/limits/>). Abort on failure is the
  documented pattern so incomplete uploads don't count against storage (Workers
  multipart example aborts in its error handler,
  <https://developers.cloudflare.com/r2/api/workers/workers-multipart-usage/>).
  DeleteBucket-vs-MPU interaction: `[UNVERIFIED]` (not documented).

### MinIO (probe §1 + source)

- **Bucket ACLs:** emulated only — GET returns a constant stub, PUT accepts only
  `private` (no-op) and 501s everything else (`cmd/acl-handlers.go`,
  <https://github.com/minio/minio/blob/be7800c8/cmd/acl-handlers.go>). Real access
  control is IAM/policy-based (`s3:GetBucketPolicy` / `s3:PutBucketPolicy`).
- **Multipart:** standard S3 MPU; 5 MiB parts accepted (probe); Complete requires the
  `?uploadId=` query (400 `BadRequest` without it — probe; handler reads uploadId from
  the form, `cmd/object-multipart-handlers.go` @ `be7800c8`); Abort idempotent (204 on
  repeat — probe). **DeleteBucket succeeds even with a live in-progress MPU and
  discards it** (probe #16). Minimum-part rejection <5 MiB not probed `[UNVERIFIED]`.

### Hitachi Vantara HCP (Hitachi API for Amazon S3)

- **Bucket ACLs:** supported and mapped to HCP namespace permissions: canned
  `public-read` sets Browse+Read for AllUsers, `private` clears them; explicit
  per-user grants (e.g. WRITE) map to native permissions
  (HCP docs mirror: <https://hs3sh.readthedocs.io/en/latest/10_addons/10_hcp_vs_aws_acls.html>;
  official page JS-gated:
  <https://docs.hitachivantara.com/r/en-us/mk-95hcph002-19/using-the-hitachi-api-for-amazon-s3/bucket-and-object-properties/access-control-lists>).
  Behavior is tenant/namespace-config dependent `[UNVERIFIED]` for current releases.
- **Multipart:** supported; max part **5 GB**, max **10,000 parts**; min part
  historically **5 MB**, relaxed to **1 MB** minimum (non-final parts) from HCP
  **9.3.0** — from release-notes snippets only, `[UNVERIFIED]`
  (<https://docs.hitachivantara.com/r/en-us/mk-95hcph002-19/using-the-hitachi-api-for-amazon-s3/working-with-multipart-uploads/about-multipart-uploads/considerations-for-working-with-multipart-uploads/support-for-multipart-uploads>).
  DeleteBucket-vs-MPU, abort retention: `[UNVERIFIED]`.

### Backblaze B2 (S3-compatible API)

- **Bucket ACLs:** bucket-level only, exactly two canned values: `private` and
  `public-read` via `PutBucketAcl`; `GetBucketAcl` works as expected; **object-level
  ACLs not supported**
  (<https://www.backblaze.com/docs/cloud-storage-s3-compatible-api>).
- **Multipart:** supported; documented Live-Read part-size range is 5,000,000 B –
  5,368,709,120 B (<https://www.backblaze.com/apidocs/s3-create-multipart-upload>);
  the general MPU min part size / max object size on the S3 API: `[UNVERIFIED]`
  (<https://www.backblaze.com/docs/cloud-storage-large-files>). Quirk: optional
  **Live Read** — ranged GET/HEAD of an object while its MPU is still uploading, opted
  in per upload via `x-backblaze-live-read-enabled: true` (same API page). A UI that
  lists objects must not assume an uploading MPU object is invisible/readable.
  DeleteBucket-vs-MPU: `[UNVERIFIED]`.

### Wasabi

- **Bucket ACLs:** `[UNVERIFIED]` (docs pages not text-extractable in this environment;
  auth/ACL pages returned but not parsed — treat ACL UI as attempt-then-surface).
- **Multipart:** adheres to the AWS S3 MPU approach; part size "must be between 5MB and
  5GB"; **incomplete multipart uploads are automatically deleted after ~31 days**
  (no lifecycle rule required), `AbortIncompleteMultipartUpload` lifecycle supported,
  uncommitted MPUs billed as active storage for 30 days
  (<https://docs.wasabi.com/docs/how-does-wasabi-handle-multipart-uploads>).
  DeleteBucket-vs-MPU: `[UNVERIFIED]`.

### DigitalOcean Spaces

- **Bucket ACLs:** exactly two canned ACLs for buckets **and** objects — `private` and
  `public-read` — applied via `x-amz-acl` header (recommended) or `PUT ?acl` XML body;
  anything else unsupported (<https://docs.digitalocean.com/products/spaces/reference/s3-compatibility/>).
- **Multipart:** supported; parts **5 MiB – 5 GB**, up to **10,000 parts**, total
  **5 TB**; `UploadPartCopy` not supported across regions/clusters; **incomplete
  multipart uploads auto-deleted after 30 days**
  (<https://docs.digitalocean.com/products/spaces/details/limits/>). Quirk: presigned
  PUT/MPU via the CDN endpoint caps payload at 8100 KiB. DeleteBucket-vs-MPU:
  `[UNVERIFIED]`.

---

## 3. Significance for threshold selection (64 MiB threshold, 16 MiB parts)

- **Part floor:** every provider's minimum (5 MiB AWS/R2/Spaces/Wasabi; 5 MB HCP
  historical; 5,000,000 B B2 Live Read) clears comfortably under 16 MiB parts —
  16 MiB ≥ 3× the strictest minimum, so one part size works everywhere.
- **Part ceiling:** 16 MiB ≪ 5 GiB max part everywhere. Never a problem.
- **Part count:** 16 MiB × 10,000 = **160 GiB**. With a fixed 16 MiB part size, objects
  above 160 GiB would exceed the 10,000-part ceiling of AWS/R2/Spaces (AWS/R2 objects
  go to 5 TiB). The uploader must grow the part size for very large files
  (e.g. `partSize = max(16 MiB, ceil(size / 10_000))`) or cap part count — the
  threshold alone does not remove the ceiling.
- **Why a 64 MiB threshold is sane:** below it, a single `PUT` avoids MPU bookkeeping
  (uploadId lifecycle, ListParts, Complete/Abort, per-part ETag state); above it,
  resumability and parallelism pay for themselves. 64 MiB = 4 × 16 MiB parts, and all
  five verified providers auto-clean or cheaply hold incomplete uploads for ≥30 days
  (Wasabi ~31 d, Spaces 30 d, AWS billed-until-aborted) — still, see §4.
- **Cleanup on failure is mandatory, not optional:** AWS bills incomplete MPUs until
  aborted/lifecycle-expired; R2 counts them against storage unless aborted; Spaces and
  Wasabi only auto-clean after ~30 days. On any MPU failure the app must
  `ListMultipartUploads` (reconcile) + `AbortMultipartUpload` the orphan. MinIO abort
  is idempotent (204 on repeat), so retrying cleanup is safe. AWS general-purpose
  DeleteBucket does **not** necessarily sweep in-progress MPUs, and MinIO's DeleteBucket
  silently discards them — never rely on bucket deletion to clean a failed upload.

---

## 4. Capability-gating checklist for the bucket ACL UI

1. **R2 — no ACLs, period.** Skip GET/PUT entirely (API compatibility page documents
   them as unimplemented); show "not supported by provider" instead of attempting.
2. **AWS — attempt, then degrade.** `GetBucketAcl` may 403 (role lacks
   `s3:GetBucketAcl`) or the bucket may be `BucketOwnerEnforced` (PUT then fails with
   `AccessControlListNotSupported`; GET still succeeds). Show read-only ACL when GET
   works; hide/disable the editor on PUT failure; on 403 mark the capability
   unavailable for the connection (don't retry per bucket).
3. **MinIO — probed: ACLs are emulation.** GET always returns the same stub
   (empty owner + FULL_CONTROL); PUT `private` is a 200 no-op, other canned ACLs → 501.
   Gate the ACL editor **off** for MinIO; expose bucket-policy management instead.
   A stub-shaped GET response is itself a usable runtime signal (§1.1).
4. **B2 / Spaces — canned two-state only.** Offer exactly `private` ⇄ `public-read`;
   HCP — supported but tenant-config dependent. For these, attempt and surface
   unavailable on **403 / 501 / NotImplemented** rather than pre-sniffing.
5. **Never let ACL capability checks block the rest of the bucket view** — ACL is an
   optional, per-connection capability negotiated at runtime, not a listed feature.
6. **Object ACLs are out of scope** for this feature (bucket ACLs + multipart only).
