# AWS SigV4 — Authoritative Sources & Test Suite

Verified: 2026-10-20 (HTTP status via `curl -sS -o /dev/null -m 15 -w '%{http_code}' -L`).

## Official specification pages

| URL | Status |
|---|---|
| <https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html> | 200 |
| <https://docs.aws.amazon.com/general/latest/gr/create-signed-request.html> | 200 |
| <https://docs.aws.amazon.com/general/latest/gr/sigv4-calculate-signature.html> | 200 |
| <https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-header-values.html> | 200 |
| <https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html> | 200 (S3-specific SigV4) |
| <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html> | 200 (temporary creds / session tokens) |

Note: `https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html` still
resolves (200) but is now a redirect shell to the General Reference welcome page — the
suite page content is gone, consistent with the suite's GitHub repo being removed.

## Test suite (official) — current status

- `https://github.com/aws/aws-sig-v4-test-suite` → **404** (repo no longer exists under the `aws` org as of 2026-10-20; previously it held the suite under Apache-2.0).
- Official-derived mirror used here: <https://github.com/saibotsivad/aws-sig-v4-test-suite> (200) — described by its author as "Check your AWS V4 signing code against the official test suite"; contains the raw suite files copied from the AWS documentation, re-published with AWS's Apache-2.0 LICENSE and NOTICE.

## Vendored copy — `docs/sigv4-suite/`

Copied from the mirror above (1.0 MB working tree → 644 K on disk, well under the 5 MB
limit). Structure:

```
docs/sigv4-suite/
├── LICENSE                 # Apache License 2.0 (Amazon.com copyright, 2019)
├── NOTICE                  # "AWS Signature Version 4 Test Suite / Copyright 2019
│                           #  Amazon.com, Inc. or its affiliates. All Rights Reserved."
└── aws-sig-v4-test-suite/  # 24 test-case directories, 157 files total
    ├── get-vanilla/            (get-vanilla.req/.creq/.sts/.authz/.sreq)
    ├── get-vanilla-query-order-key/
    ├── get-header-key-duplicate/
    ├── get-header-value-multiline/
    ├── get-header-value-order/
    ├── get-header-value-trim/
    ├── get-unreserved/
    ├── get-utf8/
    ├── get-vanilla-empty-query-key/
    ├── get-vanilla-query/
    ├── get-vanilla-query-order-key-case/
    ├── get-vanilla-query-order-value/
    ├── get-vanilla-query-unreserved/
    ├── get-vanilla-utf8-query/
    ├── normalize-path/
    ├── post-header-key-case/
    ├── post-header-key-sort/
    ├── post-header-value-case/
    ├── post-sts-token/
    └── … (24 directories total)
```

Fixed credentials used by every test case (from the suite's `get-vanilla.sts` /
`get-vanilla.authz` files): access key `AKIDEXAMPLE`, secret
`wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`, region `us-east-1`, service `service`,
date `20150830T123600Z`. `post-sts-token/` covers the `x-amz-security-token` case.

## Other official implementations (for cross-checking, not vendored)

- botocore SigV4 tests: <https://github.com/boto/botocore/blob/develop/tests/unit/auth/test_sigv4.py> (searchable mirror of suite expectations)
- AWS CRT signing tests: <https://github.com/awslabs/aws-crt-nodejs/blob/main/lib/native/auth.spec.ts>
