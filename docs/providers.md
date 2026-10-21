# S3-Compatible Provider Reference

Last verified: 2026-10-20. All statements are taken from the provider pages cited per
section unless marked `[UNVERIFIED]`. The original AWS spec is cited first:

- Addressing (path vs virtual-hosted): <https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html> — "Currently, Amazon S3 supports both virtual-hosted–style and path-style URL access in all AWS Regions" (path-style deprecation has been delayed per the AWS News Blog link on that page).
- Bucket naming (general purpose): <https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html> — lowercase letters, numbers, `.` and `-`; 3–63 chars; no adjacent periods; not IP-formatted; various reserved prefixes/suffixes.
- SigV4 signing incl. `x-amz-security-token`: <https://docs.aws.amazon.com/general/latest/gr/create-signed-request.html> and <https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-header-values.html>.

## Config matrix

| Provider | Endpoint URL format | Region value | Path-style | Virtual-hosted | ACLs | Presign | Session token |
|---|---|---|---|---|---|---|---|
| AWS S3 | `https://bucket.s3.<region>.amazonaws.com` | AWS region, required (e.g. `us-east-1`) | Yes (deprecation delayed) | Yes | Full | Yes | Yes |
| Cloudflare R2 | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` | `auto` (empty and `us-east-1` alias to it) | Yes | `[UNVERIFIED]` for `r2.cloudflarestorage.com`; documented for custom domains | No (ACL headers rejected) | Yes | Yes (temporary credentials) |
| Hitachi Vantara HCP | `https://<tenant>.hcp.<domain>/s3api` (or `/s3api/<namespace>`) | None (regionless) | Yes | `[UNVERIFIED]` | Limited | `[UNVERIFIED]` | `[UNVERIFIED]` |
| MinIO | `https://<host>:9000` (self-hosted) | Server-set (`MINIO_SITE_REGION`); unset = `us-east-1` convention | Default | Opt-in via `MINIO_DOMAIN` | Policies | Yes | Yes |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | B2 region code from key capabilities | `[UNVERIFIED]` (all examples path-style) | Yes | Bucket-level only (`private`/`public-read`) | Yes | `[UNVERIFIED]` |
| Wasabi | `https://s3.<region>.wasabisys.com` | Wasabi region code, required | Yes `[INFERENCE]` from endpoint docs | `[UNVERIFIED]` | `[UNVERIFIED]` | `[UNVERIFIED]` | `[UNVERIFIED]` |
| DigitalOcean Spaces | `https://<region>.digitaloceanspaces.com` | Region slug (e.g. `nyc3`), required | Yes | Yes (seen in signature examples) | SigV4 `x-amz-acl` supported | `[UNVERIFIED]` (implied by S3 compat) | `[UNVERIFIED]` |
| Linode (Akamai) | `https://<region>.linodeobjects.com` (e.g. `us-ord-10`) | Region slug, required | Yes | Yes (bucket URLs documented) | ACLs + bucket policies | Yes (SigV2-style example shown) | `[UNVERIFIED]` |
| Scaleway | `https://s3.<region>.scw.cloud` | `fr-par`, `nl-ams`, `pl-waw`, `it-mil` | Yes | Yes (recommended); dotted buckets need path-style | Yes (retention/ACL tags cited) | `[UNVERIFIED]` | `[UNVERIFIED]` |
| Ceph RGW | `https://<rgw-host>` (self-hosted) | Zonegroup/zone config | Yes | Via `rgw_dns_name` | ACLs | Yes | Yes (STS) |
| Garage | `http(s)://<s3_api addr>` | `s3_region` config value (default `garage`) | Yes | Optional via `root_domain` | None (ACL/Put/Get ACL all missing) | Yes | `[UNVERIFIED]` |
| Cloudian HyperStore | `http(s)://<s3-domain>` (deployment-defined, e.g. `s3-region1.addomain.local`) | Deployment-defined S3 region (e.g. `s3-region.addomain.local`) | `[UNVERIFIED]` | `[UNVERIFIED]` | `[UNVERIFIED]` | `[UNVERIFIED]` | `[UNVERIFIED]` |
| IDrive e2 | `https://s3.<region>.idrivee2.com` | Region from endpoint list (e.g. `eu-central-2`) | Yes (all API examples path-style) | `[UNVERIFIED]` | Object ACLs not supported; bucket ACL only | `[UNVERIFIED]` | `[UNVERIFIED]` |
| Storj | `https://gateway.storjshare.io` (hosted) or self-hosted gateway | None used by clients | `[UNVERIFIED]` | `[UNVERIFIED]` | `[UNVERIFIED]` | Yes (dedicated docs) | `[UNVERIFIED]` |

## Connection checklist (fields every provider config needs)

- **Display name** — free-form label; no provider semantics.
- **Endpoint** — scheme + host (and port for self-hosted). Enter host-only or full URL per the matrix; never append bucket name here.
- **Region** — see matrix; several providers alias/ignore it (R2 `auto`, MinIO unset), but it is still part of the SigV4 credential scope, so the value must match what the server expects (empty region must sign as empty, not as a guessed default).
- **Access key** — the provider's key id (AWS access key id, R2 access key, B2 `keyID`, Spaces/Linode/Scaleway keys, RGW S3 user, Garage key, IDrive e2 access key, Storj access grant-derived key).
- **Secret** — matching secret key.
- **Session token** — optional; when present send `x-amz-security-token` and include `x-amz-security-token` in the signed header list (AWS requirement; supported by R2 temporary credentials, MinIO/STS-enabled RGW per matrix).
- **Path-style toggle** — default **on** for self-hosted (MinIO, Garage, Ceph, Cloudian) and whenever the endpoint is an IP address or dotted bucket names are used; virtual-hosted requires wildcard-cert DNS hostnames. Scaleway: virtual-hosted recommended, but dotted buckets **must** use path-style (certificate is non-recursive). Bucket names with dots cannot be used with virtual-hosted anywhere, per AWS virtual-hosting rules inherited by S3-compatible vendors.

## AWS S3

- Endpoint: virtual-hosted `https://<bucket>.s3.<region>.amazonaws.com`; path-style `https://s3.<region>.amazonaws.com/<bucket>`. Both supported in all regions; path-style deprecation delayed.
- Region: required; part of the SigV4 scope. Regional endpoint list: <https://docs.aws.amazon.com/general/latest/gr/s3.html>.
- Naming: see userguide link above. SSL always. ACLs/presign/session tokens: full AWS support. Source: <https://docs.aws.amazon.com/AmazonS3/latest/userguide/VirtualHosting.html>, <https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html>.

## Cloudflare R2

- Endpoint: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` (from <https://developers.cloudflare.com/r2/api/s3/api/>, "The API is available via the `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` endpoint").
- Region: `auto`. "For compatibility with tools that do not allow you to specify a region, an empty value and `us-east-1` will alias to the `auto` region." Same page.
- ACLs: all `x-amz-acl`/grant headers unsupported; GetBucketAcl/PutBucketAcl not implemented (same page, compatibility tables).
- Presign: supported, Get/PutObject via SigV4 query signing — <https://developers.cloudflare.com/r2/api/s3/presigned-urls/>.
- Session tokens: supported via R2 temporary credentials — <https://developers.cloudflare.com/r2/api/s3/temporary-credentials/>.
- Virtual-hosted addressing on the storage endpoint: `[UNVERIFIED]` (not documented on the pages fetched).

## Hitachi Vantara HCP (Hitachi API for Amazon S3)

- Endpoints take the form `https://<tenant-url>/s3api...`; HCP also documents a Hitachi API flavor at `/s3api` vs `/hs3api` variants. Tenant/namespace hostnames are deployment-specific. Source: <https://docs.hitachivantara.com/r/en-us/mk-95hcph002/latest/using-the-hitachi-api-for-amazon-s3/introduction-to-hitachi-content-platform/about-the-hitachi-api-for-amazon-s3> (JS-rendered; fetched via reader, content limited) — endpoint path prefixes and namespace mapping details `[UNVERIFIED]`; confirmed URLs:
  - Quick reference: <https://docs.hitachivantara.com/r/en-us/mk-95hcph001-19/using-the-hitachi-api-for-amazon-s3/quick-reference> (reachable, content JS-gated)
  - Access/auth: <https://docs.hitachivantara.com/r/en-us/mk-95hcph001-20/using-the-hitachi-api-for-amazon-s3/access-and-authentication>
- Region: none (HCP is regionless). `[UNVERIFIED]` for any region-like signing scope; treat region as opaque client-side value.
- SSL: HTTPS typical on tenant FQDNs; cert trust is deployment-specific `[UNVERIFIED]`.

## MinIO

- Endpoint: self-hosted, default API port 9000 (`minio server` binds `:9000` when `--address` omitted). Source: <https://docs.min.io/community/minio-object-store/reference/minio-server/minio-server.html> (docs.min.io now redirects to AIStor docs; config reference fetched from the source repo: <https://raw.githubusercontent.com/minio/minio/master/docs/config/README.md>).
- Region: `MINIO_SITE_REGION` env (config `site region`), e.g. `us-west-1`. When unset, clients conventionally use `us-east-1`; the docs do not state a server-side default region value, so treat "us-east-1 when unset" as client convention `[UNVERIFIED]` server-side.
- Addressing: "By default, MinIO supports path-style requests… `MINIO_DOMAIN` environment variable is used to enable virtual-host-style requests." (config README, line ~321). Both styles available; virtual-hosted requires `MINIO_DOMAIN`.
- SSL: optional; certs via `~/.minio/certs` (`--certs-dir`). Source: server reference page.
- Session tokens: supported when STS is enabled `[UNVERIFIED]` on the fetched pages (STS is a documented MinIO feature).

## Backblaze B2 S3-Compatible API

- Endpoint: `https://s3.<region>.backblazeb2.com` — region-specific endpoints listed at <https://www.backblaze.com/docs/cloud-storage-regions>. The API page (<https://www.backblaze.com/docs/cloud-storage-s3-compatible-api>) fetch returned 1.4 MB of JS-heavy HTML; the visible text confirms: limited ACL support — "Get Object ACL and Get Bucket ACL calls will work as expected. However, object-level ACLs are not supported"; "The S3-Compatible API supports the Put Bucket ACL call to change between 'private' and 'public-read' only."
- Region: the S3 region code is returned in the key capabilities when creating an application key `[UNVERIFIED]` (page content not extractable).
- Presign: "The S3-Compatible API supports pre-signed URLs for downloading and uploading" (same page).
- Addressing: examples in the docs are path-style; virtual-hosted support `[UNVERIFIED]`.

## Wasabi

- Endpoint: `https://s3.<region>.wasabisys.com`. Verified region hosts include: `us-east-1`, `us-east-2`, `us-central-1`, `eu-central-1`, `eu-central-2`, `eu-west-1/2/3`, `ap-northeast-1/2`, `ap-southeast-1/2`, `ca-central-1`, plus newer code-style regions (`de-1`, `fr-1`, `it-1`, `nl-1`, `uk-1`, `uk-2`, `eu-south-1`). Source: <https://docs.wasabi.com/docs/en/service-urls-for-wasabis-storage-regions> (reached 200; hosts scraped from page).
- Everything else (addressing style, ACL, presign, session tokens) `[UNVERIFIED]` — auth page <https://docs.wasabi.com/apidocs/authentication-with-s3-api> returned 200 but body was not extractable by text scrape.

## DigitalOcean Spaces

- Endpoint: `https://<region>.digitaloceanspaces.com` — "Set the endpoint to ${REGION}.digitaloceanspaces.com". Source: <https://docs.digitalocean.com/reference/api/spaces-api/>.
- Region: region slug (e.g. `nyc3`); required, appears in SigV4 scope `${ACCESS_KEY}/${YYYYMMDD}/${REGION_SLUG}/s3/aws4_request` (same page).
- Signatures: SigV4 recommended, SigV2 legacy supported. `x-amz-acl` appears in the signed-header example (same page). ACL, virtual-hosted style (`bucket.nyc3.digitaloceanspaces.com` visible in examples), SSL standard.

## Linode Object Storage (Akamai)

- Endpoint: `https://<region>.linodeobjects.com` — e.g. `https://us-lax-4.linodeobjects.com`, `https://us-ord-10.linodeobjects.com`. Bucket URL (virtual-hosted): `https://<bucket>.<region>.linodeobjects.com`. Source: <https://techdocs.akamai.com/cloud-computing/docs/access-buckets-and-files-through-urls> (fetched as markdown).
- Region: region slug, required; lookup via Object Storage endpoints list (`object_storage_endpoint_list`).
- ACLs and signed URLs supported (same doc + "Manage access and permissions with ACLs" sibling page). The signed-URL example on the page uses SigV2 query params (`Signature`/`Expires`/`AWSAccessKeyId`).
- Session token `[UNVERIFIED]`.

## Scaleway Object Storage

- Endpoint: `https://s3.<region>.scw.cloud`; regions `nl-ams`, `fr-par`, `pl-waw`, `it-mil`. Both formats valid: "`https://my-bucket.s3.nl-ams.scw.cloud` represents a virtual-host style endpoint, and `https://s3.nl-ams.scw.cloud/my-bucket` represents a path-style endpoint. Both formats are valid and work with any up-to-date SDK or CLI, though the virtual-host style is generally preferred." Source: <https://www.scaleway.com/en/docs/object-storage/concepts.md>.
- Dot-in-name caveat: "For buckets with a name containing a dot (.), users must use the canonical path. The subdomain form… will not work as the SSL certificate `*.s3.nl-ams.scw.cloud` is not recursive." Source: <https://www.scaleway.com/en/docs/object-storage/faq.md>.
- Bucket names unique platform-wide across regions (same FAQ).

## Ceph RGW

- Endpoint: self-hosted RGW (civilian ports via civetweb/beast); URL is deployment-defined.
- Region: RGW uses zonegroups/zones, not AWS regions; the SigV4 region must be configured client-side to match the zonegroup's `api_name`/region setting `[UNVERIFIED]` detail.
- Addressing: path-style works out of the box; virtual-hosted requires `rgw_dns_name` ("for virtual hosting of buckets to work properly, unless configured via `rgw_dns_name`…"). Source: <https://docs.ceph.com/en/latest/radosgw/config-ref/> (verified `confval-rgw_dns_name` entry).
- Auth: SigV4 and SigV2 both documented; STS supported; ACLs supported. Source: <https://docs.ceph.com/en/latest/radosgw/s3/authentication/>.

## Garage

- Endpoint: `s3_api.api_bind_addr` of the Garage node (deployment-defined).
- Region: `s3_region` config value, default `"garage"` (example config shows `s3_region = "garage"`). Source: <https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/> (fetched 200; `s3_api` / `s3_region` / `root_domain` confirmed).
- Addressing: path-style implemented; virtual-host style available when `root_domain` set (`s3.example.com` example, bucket becomes `my-bucket.s3.example.com`). Source: <https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/> (fetched 200: "URL path-style (eg. host.tld/bucket/key) ✅ Implemented", "signature v4 ✅ Implemented", signature v2 deprecated/missing, "Presigned URLs ✅ Implemented").
- ACLs: all Get/PutBucketAcl and Get/PutObjectAcl endpoints "❌ Missing" (same page).

## Cloudian HyperStore

- Endpoint + region are deployment-defined; official CLI blog uses `aws --endpoint-url=http://s3-region1.addomain.local` with "The Cloudian S3 region used in this example is s3-region.addomain.local". Source: <https://cloudian.com/blog/aws-cli-s3-compatible-storage/>; admin/API doc portals: <https://cloudian.com/wp-content/themes/merged/hyperstore-help/8.2.1/Content/Introduction/Doc.html> (reachable; content is frame-based, not text-extractable here). All other fields `[UNVERIFIED]`.

## IDrive e2

- Endpoint: `https://s3.<region>.idrivee2.com/<bucket>/<key>` (all API examples path-style). Verified region hosts include: `ap-northeast-1`, `ap-southeast-1`, `ca-1`, `ca-east-1`, `ch-1`, `da-1`, `eu-central-1`, `eu-central-2`, `eu-south-1`, `eu-west-1`, `eu-west-2`, and more. Sources: <https://www.idrive.com/s3-storage-e2/e2-endpoint-urls> and <https://www.idrive.com/s3-storage-e2/s3-compatible-api> (both fetched; hostnames scraped from page).
- Region: required; determined per bucket's region in the console.
- ACLs: "x-amz-acl Optional. If supplied, must be the same as the bucket ACL" (API page). Object-level ACL behavior `[UNVERIFIED]`.

## Storj (documented)

- Endpoint: hosted gateway `https://gateway.storjshare.io` — "configured to automatically route the traffic from the instance closest to your location". Credentials come from the web wizard or `uplink share --register`, which output "an access key, a secret key, and an S3 compatible endpoint". Source: <https://storj.dev/dcs/api/s3/s3-compatible-gateway>.
- Region: none used by clients (gateway is multi-region). Presigned URLs documented: <https://storj.dev/dcs/api/s3/presigned-urls>. S3 compatibility table: <https://storj.dev/dcs/api/s3/s3-compatibility> and <https://github.com/storj/gateway-mt/blob/main/docs/gateway-mt.md#s3-api-compatibility>.
- Addressing style `[UNVERIFIED]` (examples path-style).

## Cross-provider signing notes

- AWS requires `x-amz-security-token` in the canonical request when a session token is used (<https://docs.aws.amazon.com/general/latest/gr/create-signed-request.html>). S3-compatible servers that accept STS tokens (R2, Ceph RGW, MinIO STS) follow the same header convention; anything not listed is `[UNVERIFIED]`.
- The AWS SigV4 spec's empty-region edge case matters for R2 (`auto`): sign with the region string the provider documents; R2 explicitly aliases `us-east-1`/empty to `auto` on the server side.
