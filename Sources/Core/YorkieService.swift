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

/**
 * `YorkieService` provides a wrapper around `YorkieServiceClient`, enabling
 * the addition of mocking functionality for testing and simplifying the
 * interface for higher-level API calls. This class allows users to interact
 * with Yorkie RPC APIs and manage mock responses during testing.
 */
public final class YorkieService {
    private let rpcClient: YorkieServiceClient
    private var mockErrors: [String: ConnectError] = [:]
    private var mockErrorCounts: [String: Int] = [:]
    private let isMockingEnabled: Bool

    init(rpcClient: YorkieServiceClient, isMockingEnabled: Bool = false) {
        self.rpcClient = rpcClient
        self.isMockingEnabled = isMockingEnabled
    }

    @available(iOS 15, *)
    public func activateClient(request: Yorkie_V1_ActivateClientRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_ActivateClientResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.activateClient) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.activateClient(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func deactivateClient(request: Yorkie_V1_DeactivateClientRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DeactivateClientResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.deactivateClient) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.deactivateClient(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func attachDocument(request: Yorkie_V1_AttachDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_AttachDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.attachDocument) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.attachDocument(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func detachDocument(request: Yorkie_V1_DetachDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DetachDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.detachDocument) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.detachDocument(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func removeDocument(request: Yorkie_V1_RemoveDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_RemoveDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.removeDocument) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.removeDocument(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func pushPullChanges(request: Yorkie_V1_PushPullChangesRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_PushPullChangesResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.pushPullChanges(request: request, headers: headers)
    }

    public func watchDocument(headers: Connect.Headers = [:], onResult: @escaping @Sendable (Connect.StreamResult<Yorkie_V1_WatchDocumentResponse>) -> Void) -> any Connect.ServerOnlyStreamInterface<Yorkie_V1_WatchDocumentRequest> {
        return self.rpcClient.watchDocument(headers: headers, onResult: onResult)
    }

    @available(iOS 15, *)
    public func broadcast(request: Yorkie_V1_BroadcastRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_BroadcastResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.broadcast) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.broadcast(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func attachPresence(request: Yorkie_V1_AttachPresenceRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_AttachPresenceResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.attachPresence) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.attachPresence(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func detachPresence(request: Yorkie_V1_DetachPresenceRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DetachPresenceResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.detachPresence) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.detachPresence(request: request, headers: headers)
    }

    @available(iOS 15, *)
    public func refreshPresence(request: Yorkie_V1_RefreshPresenceRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_RefreshPresenceResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.refreshPresence) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.refreshPresence(request: request, headers: headers)
    }

    public func watchPresence(headers: Connect.Headers = [:], onResult: @escaping @Sendable (Connect.StreamResult<Yorkie_V1_WatchPresenceResponse>) -> Void) -> any Connect.ServerOnlyStreamInterface<Yorkie_V1_WatchPresenceRequest> {
        return self.rpcClient.watchPresence(headers: headers, onResult: onResult)
    }
}

extension YorkieService {
    /**
     * `setMockError` sets a mock error for a specific method.
     * If mocking is enabled, this error will be returned the next time the
     * corresponding method is called.
     */
    public func setMockError(for method: Connect.MethodSpec, error: ConnectError, count: Int = 1) {
        self.mockErrors[method.name] = error
        self.mockErrorCounts[method.name] = count
    }

    /**
     * `getMockError` retrieves and removes the mock error for a specific method.
     */
    private func getMockError(for method: Connect.MethodSpec) -> ConnectError? {
        guard self.isMockingEnabled, let error = mockErrors[method.name], var count = mockErrorCounts[method.name] else {
            return nil
        }

        count -= 1
        self.mockErrorCounts[method.name] = count

        // swiftlint:disable:next empty_count
        if count <= 0 {
            self.mockErrorCounts.removeValue(forKey: method.name)
            return self.mockErrors.removeValue(forKey: method.name)
        }

        return error
    }
}
