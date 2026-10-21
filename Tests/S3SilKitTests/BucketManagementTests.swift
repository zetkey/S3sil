import Foundation
import Testing
@testable import S3SilKit

// MARK: - XML attributes and ACLs

@Test("XML nodes retain attributes, including namespace prefixes")
func xmlAttributesRetained() throws {
    let xml = """
    <Root xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Grantee xsi:type="CanonicalUser" name="alice"/>
    </Root>
    """
    let root = try S3XML.parse(Data(xml.utf8))
    let grantee = try #require(root.child("Grantee"))
    #expect(grantee.attribute("xsi:type") == "CanonicalUser")
    #expect(grantee.attribute("type") == "CanonicalUser")
    #expect(grantee.attribute("name") == "alice")
    #expect(grantee.attribute("missing") == nil)
}

@Test("Bucket ACL parses owner, canonical user, group, and inferred grantees")
func bucketACLParsing() throws {
    let xml = """
    <AccessControlPolicy xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Owner><ID>owner-id</ID><DisplayName>Owner Name</DisplayName></Owner>
      <AccessControlList>
        <Grant>
          <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
            <ID>user-id</ID><DisplayName>Alice</DisplayName>
          </Grantee>
          <Permission>FULL_CONTROL</Permission>
        </Grant>
        <Grant>
          <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
            <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
          </Grantee>
          <Permission>READ</Permission>
        </Grant>
        <Grant>
          <Grantee><ID>inferred-id</ID></Grantee>
          <Permission>WRITE</Permission>
        </Grant>
      </AccessControlList>
    </AccessControlPolicy>
    """
    let acl = try S3XML.parseBucketACL(Data(xml.utf8))
    #expect(acl.ownerID == "owner-id")
    #expect(acl.ownerDisplayName == "Owner Name")
    #expect(acl.grants.count == 3)
    #expect(acl.grants[0].granteeType == .canonicalUser)
    #expect(acl.grants[0].granteeID == "user-id")
    #expect(acl.grants[0].displayName == "Alice")
    #expect(acl.grants[0].permission == "FULL_CONTROL")
    #expect(acl.grants[1].granteeType == .group)
    #expect(acl.grants[1].uri == "http://acs.amazonaws.com/groups/global/AllUsers")
    #expect(acl.grants[2].granteeType == .canonicalUser)
    #expect(acl.grants[2].granteeID == "inferred-id")
}

@Test("Invalid ACL documents throw")
func invalidACLDocument() {
    #expect(throws: S3Error.self) {
        try S3XML.parseBucketACL(Data("<ListBucketResult/>".utf8))
    }
}

// MARK: - Multipart XML

@Test("Multipart upload ID parses from the initiate response")
func multipartUploadIDParsing() throws {
    let xml = """
    <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Bucket>my-bucket</Bucket>
      <Key>large file.bin</Key>
      <UploadId>upload-id-123</UploadId>
    </InitiateMultipartUploadResult>
    """
    #expect(try S3XML.parseUploadID(Data(xml.utf8)) == "upload-id-123")
}

@Test("Missing multipart upload ID throws")
func missingMultipartUploadID() {
    #expect(throws: S3Error.self) {
        try S3XML.parseUploadID(Data("<InitiateMultipartUploadResult/>".utf8))
    }
}

@Test("CompleteMultipartUpload body quotes and escapes ETags")
func completeMultipartBody() throws {
    let body = S3XML.completeMultipartUploadBody(parts: [
        UploadedPart(partNumber: 1, etag: "\"abc&def\""),
        UploadedPart(partNumber: 2, etag: "plain")
    ])
    let text = String(decoding: body, as: UTF8.self)
    #expect(text.hasPrefix("<CompleteMultipartUpload>"))
    #expect(text.contains("<PartNumber>1</PartNumber>"))
    #expect(text.contains("<ETag>&quot;abc&amp;def&quot;</ETag>"))
    #expect(text.contains("<ETag>&quot;plain&quot;</ETag>"))
    #expect(text.hasSuffix("</CompleteMultipartUpload>"))

    // The body must remain well-formed after escaping.
    _ = try S3XML.parse(body)
}

// MARK: - CreateBucket body

@Test("AWS sends a location constraint only outside us-east-1")
func createBucketBodyAWS() throws {
    #expect(S3XML.createBucketConfiguration(provider: .aws, region: "us-east-1") == nil)
    #expect(S3XML.createBucketConfiguration(provider: .aws, region: "US-EAST-1") == nil)
    let body = try #require(S3XML.createBucketConfiguration(provider: .aws, region: "eu-central-1"))
    let text = String(decoding: body, as: UTF8.self)
    #expect(text.contains("<LocationConstraint>eu-central-1</LocationConstraint>"))
}

@Test("Non-AWS providers never send a CreateBucket location body")
func createBucketBodyProviders() {
    for provider in ProviderKind.allCases where provider != .aws {
        #expect(S3XML.createBucketConfiguration(provider: provider, region: "eu-central-1") == nil)
        #expect(S3XML.createBucketConfiguration(provider: provider, region: "us-west-2") == nil)
    }
}

// MARK: - Bucket name validation

@Test("Bucket names must be 3–63 characters with no slash or whitespace")
func bucketNameCommonRules() {
    #expect(BucketNameValidator.validationError(for: "ab", provider: .minio) != nil)
    #expect(BucketNameValidator.validationError(for: String(repeating: "a", count: 64), provider: .minio) != nil)
    #expect(BucketNameValidator.validationError(for: "bad/name", provider: .minio) != nil)
    #expect(BucketNameValidator.validationError(for: "bad name", provider: .minio) != nil)
    #expect(BucketNameValidator.validationError(for: "", provider: .minio) != nil)
    #expect(BucketNameValidator.validationError(for: "good-name", provider: .minio) == nil)
    #expect(BucketNameValidator.validationError(for: String(repeating: "a", count: 63), provider: .generic) == nil)
}

@Test("AWS-only naming rules do not apply to other providers")
func bucketNameProviderRules() {
    #expect(BucketNameValidator.validationError(for: "Mixed_Case", provider: .aws) != nil)
    #expect(BucketNameValidator.validationError(for: "Mixed_Case", provider: .minio) == nil)
    #expect(BucketNameValidator.validationError(for: "Mixed_Case", provider: .generic) == nil)
    #expect(BucketNameValidator.validationError(for: "-leading", provider: .aws) != nil)
    #expect(BucketNameValidator.validationError(for: "-leading", provider: .hitachi) == nil)
    #expect(BucketNameValidator.validationError(for: "a..b", provider: .aws) != nil)
    #expect(BucketNameValidator.validationError(for: "192.168.1.1", provider: .aws) != nil)
    #expect(BucketNameValidator.validationError(for: "192.168.1.1", provider: .generic) == nil)
    #expect(BucketNameValidator.validationError(for: "valid-name.1", provider: .aws) == nil)
}

// MARK: - Multipart plan

@Test("Small files stay on single PutObject")
func multipartPlanBelowThreshold() {
    #expect(MultipartUploadPlan.plan(totalBytes: 0) == nil)
    #expect(MultipartUploadPlan.plan(totalBytes: MultipartUploadPlan.defaultThreshold - 1) == nil)
    #expect(MultipartUploadPlan.plan(totalBytes: 12 * 1024 * 1024) == nil)
}

@Test("Multipart plan uses 16 MiB parts at the 64 MiB threshold")
func multipartPlanThreshold() throws {
    let plan = try #require(MultipartUploadPlan.plan(totalBytes: 64 * 1024 * 1024))
    #expect(plan.partSize == 16 * 1024 * 1024)
    #expect(plan.partCount == 4)
    #expect(plan.offset(forPart: 1) == 0)
    #expect(plan.offset(forPart: 4) == 48 * 1024 * 1024)
    #expect(plan.length(forPart: 4) == 16 * 1024 * 1024)
}

@Test("Custom 5 MiB parts split a 12 MiB file into 5 + 5 + 2 MiB")
func multipartPlanCustomParts() throws {
    let size: Int64 = 12 * 1024 * 1024
    let part: Int64 = 5 * 1024 * 1024
    let plan = try #require(MultipartUploadPlan.plan(totalBytes: size, partSize: part, threshold: 0))
    #expect(plan.partCount == 3)
    #expect(plan.length(forPart: 1) == part)
    #expect(plan.length(forPart: 2) == part)
    #expect(plan.length(forPart: 3) == 2 * 1024 * 1024)
    #expect(plan.length(forPart: 1) + plan.length(forPart: 2) + plan.length(forPart: 3) == size)
}

@Test("Part size is at least 5 MiB")
func multipartPlanMinimumPartSize() throws {
    let plan = try #require(MultipartUploadPlan.plan(
        totalBytes: 6 * 1024 * 1024,
        partSize: 1024 * 1024,
        threshold: 0
    ))
    #expect(plan.partSize == 5 * 1024 * 1024)
    #expect(plan.partCount == 2)
}

@Test("Huge files scale the part size to stay under 10,000 parts")
func multipartPlanScaling() throws {
    let size: Int64 = 200 * 1024 * 1024 * 1024
    let plan = try #require(MultipartUploadPlan.plan(totalBytes: size))
    #expect(plan.partSize >= MultipartUploadPlan.minimumPartSize)
    #expect(plan.partCount <= MultipartUploadPlan.maximumPartCount)
    var sum: Int64 = 0
    for number in 1...plan.partCount {
        let length = plan.length(forPart: number)
        #expect(length > 0)
        #expect(length <= plan.partSize)
        sum += length
    }
    #expect(sum == size)
    #expect(plan.partCount > 1)
}

@Test("ACL editor is gated off for R2 and MinIO")
func providerACLCapability() {
    #expect(ProviderKind.cloudflareR2.supportsACLs == false)
    #expect(ProviderKind.cloudflareR2.showsBucketACLInfo == false)
    guard case .unsupported = ProviderKind.cloudflareR2.bucketACLCapability else {
        Issue.record("R2 must have no ACL capability")
        return
    }

    // MinIO GET returns a stub and PUT private is a no-op, so it gets an explanation, not an editor.
    #expect(ProviderKind.minio.supportsACLs == false)
    #expect(ProviderKind.minio.showsBucketACLInfo)
    guard case .readOnly(let reason) = ProviderKind.minio.bucketACLCapability else {
        Issue.record("MinIO must be read-only for ACLs")
        return
    }
    #expect(reason.contains("does not enforce"))
    #expect(ProviderKind.minio.aclSummary == "ACLs not enforced")

    for provider in [ProviderKind.aws, .hitachi, .generic] {
        #expect(provider.supportsACLs)
        #expect(provider.showsBucketACLInfo)
        #expect(provider.aclSummary == nil)
    }
}
