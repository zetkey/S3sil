import Foundation
import Testing
@testable import S3SilKit

// Sample response from the official ListObjectsV2 API reference:
// https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html
private let documentedListResponse = """
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>quotes</Name>
  <Prefix>E</Prefix>
  <StartAfter>ExampleGuide.pdf</StartAfter>
  <KeyCount>1</KeyCount>
  <MaxKeys>3</MaxKeys>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>ExampleObject.txt</Key>
    <LastModified>2013-09-17T18:07:53.000Z</LastModified>
    <ETag>"599bab3ed2c697f1d26842727561fd94"</ETag>
    <Size>857</Size>
    <StorageClass>REDUCED_REDUNDANCY</StorageClass>
  </Contents>
</ListBucketResult>
"""

// Official S3 error format:
// https://docs.aws.amazon.com/AmazonS3/latest/developerguide/ErrorResponses.html
private let documentedError = """
<?xml version="1.0" encoding="UTF-8"?>
<Error>
  <Code>NoSuchKey</Code>
  <Message>The resource you requested does not exist</Message>
  <Resource>/mybucket/myfoto.jpg</Resource>
  <RequestId>4442587FB7D0A2F9</RequestId>
</Error>
"""

@Test("Documented ListObjectsV2 response parses")
func documentedList() throws {
    let listing = try S3XML.parseObjectListing(Data(documentedListResponse.utf8), prefix: "", delimiter: "/")
    #expect(listing.objects.count == 1)
    #expect(listing.isTruncated == false)
    #expect(listing.nextToken == nil)
    let object = try #require(listing.objects.first)
    #expect(object.key == "ExampleObject.txt")
    #expect(object.name == "ExampleObject.txt")
    #expect(object.size == 857)
    #expect(object.etag == "599bab3ed2c697f1d26842727561fd94")
    #expect(object.storageClass == "REDUCED_REDUNDANCY")
    #expect(object.kind == .file)
    #expect(object.lastModified != nil)
}

@Test("Folders, relative names, and continuation tokens parse")
func foldersAndPagination() throws {
    let xml = """
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>my-bucket</Name>
      <Prefix>photos/</Prefix>
      <IsTruncated>true</IsTruncated>
      <NextContinuationToken>1ueGcxLPRx/abc+def=</NextContinuationToken>
      <Contents>
        <Key>photos/a &amp; b.jpg</Key>
        <LastModified>2024-01-02T03:04:05.000Z</LastModified>
        <ETag>&quot;abc&quot;</ETag>
        <Size>12</Size>
        <StorageClass>STANDARD</StorageClass>
      </Contents>
      <CommonPrefixes><Prefix>photos/2024/</Prefix></CommonPrefixes>
      <CommonPrefixes><Prefix>photos/archive/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """
    let listing = try S3XML.parseObjectListing(Data(xml.utf8), prefix: "photos/", delimiter: "/")
    #expect(listing.isTruncated)
    #expect(listing.nextToken == "1ueGcxLPRx/abc+def=")
    #expect(listing.objects.count == 3)

    let file = try #require(listing.objects.first { $0.kind == .file })
    #expect(file.name == "a & b.jpg")
    #expect(file.key == "photos/a & b.jpg")
    #expect(file.etag == "abc")

    let folders = listing.objects.filter(\.isFolder)
    #expect(folders.map(\.name) == ["2024", "archive"])
    #expect(folders.first?.key == "photos/2024/")
}

// HCP and B2 include folder markers as Contents objects, and may also repeat
// child markers in CommonPrefixes.
private let markerListResponse = """
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>documents</Name>
  <Prefix>Documents/</Prefix>
  <Delimiter>/</Delimiter>
  <IsTruncated>false</IsTruncated>
  <Contents>
    <Key>Documents/</Key>
    <LastModified>2024-05-01T00:00:00.000Z</LastModified>
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag>
    <Size>0</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>Documents/Reports/</Key>
    <LastModified>2024-05-01T00:00:00.000Z</LastModified>
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag>
    <Size>0</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <Contents>
    <Key>Documents/readme.txt</Key>
    <LastModified>2024-05-02T03:04:05.000Z</LastModified>
    <ETag>&quot;abc&quot;</ETag>
    <Size>42</Size>
    <StorageClass>STANDARD</StorageClass>
  </Contents>
  <CommonPrefixes><Prefix>Documents/Reports/</Prefix></CommonPrefixes>
  <CommonPrefixes><Prefix>Documents/Archive/</Prefix></CommonPrefixes>
</ListBucketResult>
"""

@Test("Parent marker and duplicated folder markers collapse into folders")
func markerListingDeduplication() throws {
    let listing = try S3XML.parseObjectListing(
        Data(markerListResponse.utf8),
        prefix: "Documents/",
        delimiter: "/"
    )
    #expect(listing.objects.count == 3)
    #expect(!listing.objects.contains { $0.key == "Documents/" })

    let folders = listing.objects.filter(\.isFolder)
    #expect(folders.map(\.key) == ["Documents/Reports/", "Documents/Archive/"])
    #expect(folders.map(\.name) == ["Reports", "Archive"])

    let files = listing.objects.filter { !$0.isFolder }
    #expect(files.map(\.key) == ["Documents/readme.txt"])
    #expect(files.first?.size == 42)
}

@Test("Root listing emits one row for a marker repeated in CommonPrefixes")
func rootMarkerDeduplication() throws {
    let xml = """
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>photos</Name>
      <Prefix></Prefix>
      <Delimiter>/</Delimiter>
      <IsTruncated>false</IsTruncated>
      <Contents>
        <Key>Photos/</Key>
        <LastModified>2024-05-01T00:00:00.000Z</LastModified>
        <Size>0</Size>
      </Contents>
      <CommonPrefixes><Prefix>Photos/</Prefix></CommonPrefixes>
    </ListBucketResult>
    """
    let listing = try S3XML.parseObjectListing(Data(xml.utf8), prefix: "", delimiter: "/")
    #expect(listing.objects.map(\.key) == ["Photos/"])
    #expect(listing.objects.first?.kind == .folder)
    #expect(listing.objects.first?.name == "Photos")
}

@Test("Recursive listing keeps the folder marker so it can be deleted")
func recursiveMarkerRetained() throws {
    let listing = try S3XML.parseObjectListing(
        Data(markerListResponse.utf8),
        prefix: "Documents/",
        delimiter: nil
    )
    let marker = try #require(listing.objects.first { $0.key == "Documents/" })
    #expect(marker.kind == .file)
    #expect(marker.size == 0)
    // ObjectBrowserModel.allKeys collects non-folder keys from recursive listings.
    #expect(listing.objects.filter { !$0.isFolder }.map(\.key).contains("Documents/"))
}

@Test("Documented S3 error XML parses into S3Error")
func documentedErrorParsing() throws {
    let error = S3Error.from(
        data: Data(documentedError.utf8),
        statusCode: 404,
        headers: ["x-amz-bucket-region": "us-west-2"]
    )
    #expect(error.code == "NoSuchKey")
    #expect(error.message == "The resource you requested does not exist")
    #expect(error.requestID == "4442587FB7D0A2F9")
    #expect(error.resource == "/mybucket/myfoto.jpg")
    #expect(error.statusCode == 404)
    #expect(error.regionHint == "us-west-2")
    #expect(error.title == "Object Not Found")
    #expect(error.alertMessage.contains("Request ID: 4442587FB7D0A2F9"))
}

@Test("Non-XML error bodies fall back to HTTP status")
func plainErrorParsing() {
    let error = S3Error.from(data: Data("<html>bad gateway</html>".utf8), statusCode: 502)
    #expect(error.statusCode == 502)
    #expect(error.title == "Server Error")
    #expect(error.code == nil)
}

@Test("Bucket listing parses")
func bucketListing() throws {
    let xml = """
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Owner><ID>owner</ID><DisplayName>me</DisplayName></Owner>
      <Buckets>
        <Bucket><Name>alpha</Name><CreationDate>2020-01-01T00:00:00.000Z</CreationDate></Bucket>
        <Bucket><Name>beta</Name><CreationDate>2021-02-03T04:05:06.000Z</CreationDate></Bucket>
      </Buckets>
    </ListAllMyBucketsResult>
    """
    let buckets = try S3XML.parseBuckets(Data(xml.utf8))
    #expect(buckets.map(\.name) == ["alpha", "beta"])
    #expect(buckets[0].creationDate != nil)
}

@Test("DeleteObjects failures parse")
func deleteFailures() throws {
    let xml = """
    <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Deleted><Key>ok.txt</Key></Deleted>
      <Error><Key>denied.txt</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
    </DeleteResult>
    """
    let failures = try S3XML.parseDeleteFailures(Data(xml.utf8))
    #expect(failures == [DeleteFailure(key: "denied.txt", code: "AccessDenied", message: "Access Denied")])
}

@Test("Malformed XML throws a readable error")
func malformedXML() {
    #expect(throws: S3Error.self) {
        try S3XML.parse(Data("<ListBucketResult><Contents>".utf8))
    }
}
