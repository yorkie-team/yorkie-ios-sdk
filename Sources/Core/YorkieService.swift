/*
 * Copyright 2022 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Connect
import Foundation
import SwiftProtobuf

/**
 * `YorkieService` provides a wrapper around `YorkieServiceClient`, enabling
 * the addition of mocking functionality for testing and simplifying the
 * interface for higher-level API calls. This class allows users to interact
 * with Yorkie RPC APIs and manage mock responses during testing.
 */
public final class YorkieService {
    private let rpcClient: YorkieServiceClient
    /// Guards the test-seam state below. Tests arm the seams from the main actor while the
    /// nonisolated RPC methods read them from whatever task made the call. Every access sits
    /// behind `isMockingEnabled`, so a client with mocking off never touches the lock.
    private let seamLock = NSLock()
    private var mockErrors: [String: ConnectError] = [:]
    private var mockErrorCounts: [String: Int] = [:]
    private let isMockingEnabled: Bool
    private var mockErrorPredicates: [String: (any Message) -> Bool] = [:]
    private var requestObservers: [String: (any Message) -> Void] = [:]
    private var responseHooks: [String: (any Message) async -> Void] = [:]
    private var watchResponseObserver: (@Sendable (Yorkie_V1_WatchResponse) -> Void)?

    init(rpcClient: YorkieServiceClient, isMockingEnabled: Bool = false) {
        self.rpcClient = rpcClient
        self.isMockingEnabled = isMockingEnabled
    }

    @available(iOS 15, *)
    public func activateClient(request: Yorkie_V1_ActivateClientRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_ActivateClientResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.activateClient) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.activateClient, request: request) {
            await self.rpcClient.activateClient(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func deactivateClient(request: Yorkie_V1_DeactivateClientRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DeactivateClientResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.deactivateClient) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.deactivateClient, request: request) {
            await self.rpcClient.deactivateClient(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func attachDocument(request: Yorkie_V1_AttachDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_AttachDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.attachDocument) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.attachDocument, request: request) {
            await self.rpcClient.attachDocument(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func detachDocument(request: Yorkie_V1_DetachDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DetachDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.detachDocument) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.detachDocument, request: request) {
            await self.rpcClient.detachDocument(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func removeDocument(request: Yorkie_V1_RemoveDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_RemoveDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.removeDocument) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.removeDocument, request: request) {
            await self.rpcClient.removeDocument(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func createRevision(request: Yorkie_V1_CreateRevisionRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_CreateRevisionResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.createRevision) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.createRevision, request: request) {
            await self.rpcClient.createRevision(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func getRevision(request: Yorkie_V1_GetRevisionRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_GetRevisionResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.getRevision) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.getRevision, request: request) {
            await self.rpcClient.getRevision(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func listRevisions(request: Yorkie_V1_ListRevisionsRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_ListRevisionsResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.listRevisions) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.listRevisions, request: request) {
            await self.rpcClient.listRevisions(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func restoreRevision(request: Yorkie_V1_RestoreRevisionRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_RestoreRevisionResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.restoreRevision) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.restoreRevision, request: request) {
            await self.rpcClient.restoreRevision(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func pushPullChanges(request: Yorkie_V1_PushPullChangesRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_PushPullChangesResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges, request: request) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.pushPullChanges, request: request) {
            await self.rpcClient.pushPullChanges(request: request, headers: headers)
        }
    }

    public func watch(headers: Connect.Headers = [:], onResult: @escaping @Sendable (Connect.StreamResult<Yorkie_V1_WatchResponse>) -> Void) -> any Connect.ServerOnlyStreamInterface<Yorkie_V1_WatchRequest> {
        guard self.isMockingEnabled, let observer = self.seamLock.withLock({ self.watchResponseObserver }) else {
            return self.rpcClient.watch(headers: headers, onResult: onResult)
        }
        return self.rpcClient.watch(headers: headers, onResult: { result in
            if case .message(let message) = result {
                observer(message)
            }
            onResult(result)
        })
    }

    @available(iOS 15, *)
    public func broadcast(request: Yorkie_V1_BroadcastRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_BroadcastResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.broadcast) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.broadcast, request: request) {
            await self.rpcClient.broadcast(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func attachChannel(request: Yorkie_V1_AttachChannelRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_AttachChannelResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.attachChannel) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.attachChannel, request: request) {
            await self.rpcClient.attachChannel(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func detachChannel(request: Yorkie_V1_DetachChannelRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DetachChannelResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.detachChannel) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.detachChannel, request: request) {
            await self.rpcClient.detachChannel(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func refreshChannel(request: Yorkie_V1_RefreshChannelRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_RefreshChannelResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.refreshChannel) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.refreshChannel, request: request) {
            await self.rpcClient.refreshChannel(request: request, headers: headers)
        }
    }

    @available(iOS 15, *)
    public func peekChannel(request: Yorkie_V1_PeekChannelRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_PeekChannelResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.peekChannel) {
            return .init(result: .failure(error))
        }
        return await self.intercept(YorkieServiceClient.Metadata.Methods.peekChannel, request: request) {
            await self.rpcClient.peekChannel(request: request, headers: headers)
        }
    }
}

extension YorkieService {
    /**
     * `setMockError` sets a mock error for a specific method.
     * If mocking is enabled, this error will be returned the next time the
     * corresponding method is called.
     */
    public func setMockError(for method: Connect.MethodSpec, error: ConnectError, count: Int = 1) {
        self.seamLock.withLock {
            self.mockErrors[method.name] = error
            self.mockErrorCounts[method.name] = count
            self.mockErrorPredicates.removeValue(forKey: method.name)
        }
    }

    /**
     * `getMockError` retrieves and removes the mock error for a specific method.
     */
    private func getMockError(for method: Connect.MethodSpec, request: (any Message)? = nil) -> ConnectError? {
        guard self.isMockingEnabled else {
            return nil
        }

        // The predicate runs under the lock, so it must not call back into the service.
        return self.seamLock.withLock {
            guard let error = self.mockErrors[method.name], var count = self.mockErrorCounts[method.name] else {
                return nil
            }

            // A mock error armed with a predicate fires only for the requests it accepts, and a
            // call that does not pass its request cannot satisfy one.
            if let predicate = self.mockErrorPredicates[method.name], !(request.map(predicate) ?? false) {
                return nil
            }

            count -= 1
            self.mockErrorCounts[method.name] = count

            // swiftlint:disable:next empty_count
            if count <= 0 {
                self.mockErrorCounts.removeValue(forKey: method.name)
                self.mockErrorPredicates.removeValue(forKey: method.name)
                return self.mockErrors.removeValue(forKey: method.name)
            }

            return error
        }
    }
}

// MARK: - Test seam (mocking only)

extension YorkieService {
    /// Observes every request sent through `method`, before the RPC is made.
    ///
    /// Internal test seam, live only when mocking is enabled: with mocking disabled the observer is
    /// never stored and never called. A later call for the same method replaces the earlier
    /// observer; pass `nil` to remove it. It is not called when a mock error
    /// (``setMockError(for:error:count:)``) short-circuits the call. Streaming RPCs (`watch`)
    /// are not covered; see ``observeWatchResponses(_:)``.
    func observeRequests(for method: Connect.MethodSpec, _ observer: ((any Message) -> Void)?) {
        guard self.isMockingEnabled else {
            return
        }
        self.seamLock.withLock { self.requestObservers[method.name] = observer }
    }

    /// Observes every message the Watch streams opened after this call deliver, before the client
    /// handles it, so a test can read the init response and the heartbeats the client otherwise
    /// consumes silently.
    ///
    /// Internal test seam, live only when mocking is enabled. It applies to streams opened after
    /// the call, and a later call replaces the earlier observer; pass `nil` to remove it. The
    /// observer runs on the transport's callback queue, not the main actor.
    func observeWatchResponses(_ observer: (@Sendable (Yorkie_V1_WatchResponse) -> Void)?) {
        guard self.isMockingEnabled else {
            return
        }
        self.seamLock.withLock { self.watchResponseObserver = observer }
    }

    /// Arms a mock error that fires for every request `predicate` accepts, and for none other.
    ///
    /// Internal test seam, live only when mocking is enabled, and applied to `pushPullChanges`
    /// alone. It lets a test refuse one document while the client's others sync normally. The
    /// error stays armed until the method's mock error is replaced, so a test ends the refusal by
    /// making the predicate answer `false`.
    func setMockError(for method: Connect.MethodSpec, error: ConnectError, where predicate: @escaping (any Message) -> Bool) {
        guard self.isMockingEnabled else {
            return
        }
        self.seamLock.withLock {
            self.mockErrors[method.name] = error
            self.mockErrorCounts[method.name] = Int.max
            self.mockErrorPredicates[method.name] = predicate
        }
    }

    /// Runs `hook` after the real RPC for `method` has returned and before its response is
    /// delivered to the caller, so a test can inspect the response or suspend inside the hook to
    /// hold it.
    ///
    /// Internal test seam, live only when mocking is enabled. The hook receives the response
    /// message and is skipped when the RPC failed. A later call for the same method replaces the
    /// earlier hook; pass `nil` to remove it.
    func setResponseHook(for method: Connect.MethodSpec, _ hook: ((any Message) async -> Void)?) {
        guard self.isMockingEnabled else {
            return
        }
        self.seamLock.withLock { self.responseHooks[method.name] = hook }
    }

    /// Makes `call` and routes it through the test seam. With mocking disabled it is a plain call.
    private func intercept<Req: Message, Res: Message>(
        _ method: Connect.MethodSpec,
        request: Req,
        _ call: () async -> ResponseMessage<Res>
    ) async -> ResponseMessage<Res> {
        guard self.isMockingEnabled else {
            return await call()
        }

        // Read under the lock, called outside it: an observer may be slow and a hook suspends.
        let observer = self.seamLock.withLock { self.requestObservers[method.name] }
        observer?(request)
        let response = await call()
        if let message = response.message, let hook = self.seamLock.withLock({ self.responseHooks[method.name] }) {
            await hook(message)
        }
        return response
    }
}
