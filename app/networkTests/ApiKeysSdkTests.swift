//
//  ApiKeysSdkTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The SDK side of Account > API keys: the store's copy of the typed answers
 * of Api.ListApiKeys, Api.CreateApiKey and Api.DeleteApiKey (a request
 * error, a result error, or a result without what the screen needs is a
 * failure, and no message is kept), and the account api's delete refusing an
 * id it cannot parse before any request. No request is sent.
 */
struct ApiKeysSdkTests {

    // test-only key ids
    private static let olderKey = "0193b1e6-5b6d-4e7f-8a9b-0c1d2e3f4a5b"
    private static let newerKey = "0193b1e7-5b6d-4e7f-8a9b-0c1d2e3f4a5c"
    // a test-only key in the server's form, never a real one
    private static let secret = "urn_TESTONLY00000000000000000000000000000000000000000000"

    private static func id(_ value: String) throws -> SdkId {
        try #require(SdkParseId(value, nil))
    }

    private static func apiError() -> SdkApiError {
        let error = SdkApiError()
        error.message = "a raw message the screen never shows"
        return error
    }

    private static let requestError = NSError(domain: "ApiKeysSdkTests", code: 1)

    /// The answer the account api gave, on whatever thread it answered.
    private final class Answer<Value>: @unchecked Sendable {
        var value: Value?
    }

    // MARK: List

    @Test func theListIsCopiedFieldByField() throws {
        let named = SdkPublicAccountApiKey()
        named.id_ = try Self.id(Self.olderKey)
        named.name = "home server"
        named.createTime = SdkTime(unixMilli: 1_791_000_000_000)

        // created through the API with no name, and no time sent
        let unnamed = SdkPublicAccountApiKey()
        unnamed.id_ = try Self.id(Self.newerKey)

        // a key without an id cannot be deleted, so it is not listed
        let noId = SdkPublicAccountApiKey()
        noId.name = "no id"

        let list = SdkPublicAccountApiKeyList()
        list.add(named)
        list.add(unnamed)
        list.add(noId)
        let result = SdkListApiKeysResult()
        result.apiKeys = list

        // in the server's order; the store sorts
        #expect(ApiKeysAnswers.list(result, err: nil) == .success([
            ApiKeyItem(id: Self.olderKey, name: "home server", createTimeMillis: 1_791_000_000_000),
            ApiKeyItem(id: Self.newerKey, name: "", createTimeMillis: nil),
        ]))
    }

    // the server sends no list at all for a network without keys
    @Test func noListIsNoKeys() {
        #expect(ApiKeysAnswers.list(SdkListApiKeysResult(), err: nil) == .success([]))
        let result = SdkListApiKeysResult()
        result.apiKeys = SdkPublicAccountApiKeyList()
        #expect(ApiKeysAnswers.list(result, err: nil) == .success([]))
    }

    @Test func aFailedListIsAFailure() {
        let refused = SdkListApiKeysResult()
        refused.error = Self.apiError()
        #expect(ApiKeysAnswers.list(refused, err: nil) == .failure(ApiKeysRequestFailed()))
        #expect(ApiKeysAnswers.list(nil, err: Self.requestError) == .failure(ApiKeysRequestFailed()))
        #expect(ApiKeysAnswers.list(SdkListApiKeysResult(), err: Self.requestError) == .failure(ApiKeysRequestFailed()))
        #expect(ApiKeysAnswers.list(nil, err: nil) == .failure(ApiKeysRequestFailed()))
    }

    // MARK: Create

    @Test func aCreatedKeyIsCopied() throws {
        let result = SdkCreateApiKeyResult()
        result.id_ = try Self.id(Self.newerKey)
        result.apiKey = Self.secret
        result.name = "build bot"
        #expect(ApiKeysAnswers.created(result, err: nil) == .success(
            ApiKeyCreatedItem(id: Self.newerKey, name: "build bot", apiKey: Self.secret)
        ))
    }

    @Test func aCreateWithoutTheKeyOrItsIdIsAFailure() throws {
        let noKey = SdkCreateApiKeyResult()
        noKey.id_ = try Self.id(Self.newerKey)
        noKey.name = "build bot"
        #expect(ApiKeysAnswers.created(noKey, err: nil) == .failure(ApiKeysRequestFailed()))

        let noId = SdkCreateApiKeyResult()
        noId.apiKey = Self.secret
        #expect(ApiKeysAnswers.created(noId, err: nil) == .failure(ApiKeysRequestFailed()))
    }

    @Test func aFailedCreateIsAFailure() throws {
        let refused = SdkCreateApiKeyResult()
        refused.error = Self.apiError()
        #expect(ApiKeysAnswers.created(refused, err: nil) == .failure(ApiKeysRequestFailed()))
        #expect(ApiKeysAnswers.created(nil, err: Self.requestError) == .failure(ApiKeysRequestFailed()))
        #expect(ApiKeysAnswers.created(nil, err: nil) == .failure(ApiKeysRequestFailed()))
    }

    // MARK: Delete

    @Test func aDeleteSucceedsWithoutAnError() {
        #expect(Self.deleted(ApiKeysAnswers.deleted(SdkDeleteApiKeyResult(), err: nil)))
    }

    @Test func aFailedDeleteIsAFailure() {
        let refused = SdkDeleteApiKeyResult()
        refused.error = Self.apiError()
        #expect(!Self.deleted(ApiKeysAnswers.deleted(refused, err: nil)))
        #expect(!Self.deleted(ApiKeysAnswers.deleted(nil, err: Self.requestError)))
        #expect(!Self.deleted(ApiKeysAnswers.deleted(nil, err: nil)))
    }

    private static func deleted(_ result: Result<Void, ApiKeysRequestFailed>) -> Bool {
        if case .success = result {
            return true
        }
        return false
    }

    // an id that is not one fails at once, before any request, on the
    // account api of a real network space
    @Test func theAccountApiRefusesAnIdItCannotParse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "api-keys-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spaceManager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            spaceManager.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try #require(SdkNewNetworkSpaceKey("api-keys.example", "test"))
        let space = try #require(spaceManager.updateNetworkSpaceValues(key, values: values))
        let api = try #require(space.getApi())

        let answer = Answer<Result<Void, ApiKeysRequestFailed>>()
        api.removeApiKey(id: "not an id") { result in
            answer.value = result
        }
        let result = try #require(answer.value)
        #expect(!Self.deleted(result))
    }
}
