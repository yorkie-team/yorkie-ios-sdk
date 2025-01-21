//
//  YorkieService.swift
//  Yorkie
//
//  Created by KSB on 1/20/25.
//

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
    private let isMockingEnabled: Bool

    init(rpcClient: YorkieServiceClient, isMockingEnabled: Bool = false) {
        self.rpcClient = rpcClient
        self.isMockingEnabled = isMockingEnabled
    }

    @available(iOS 13, *)
    public func activateClient(request: Yorkie_V1_ActivateClientRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_ActivateClientResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.activateClient) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.activateClient(request: request, headers: headers)
    }

    @available(iOS 13, *)
    public func deactivateClient(request: Yorkie_V1_DeactivateClientRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DeactivateClientResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.deactivateClient) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.deactivateClient(request: request, headers: headers)
    }

    @available(iOS 13, *)
    public func attachDocument(request: Yorkie_V1_AttachDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_AttachDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.attachDocument) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.attachDocument(request: request, headers: headers)
    }

    @available(iOS 13, *)
    public func detachDocument(request: Yorkie_V1_DetachDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_DetachDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.detachDocument) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.detachDocument(request: request, headers: headers)
    }

    @available(iOS 13, *)
    public func removeDocument(request: Yorkie_V1_RemoveDocumentRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_RemoveDocumentResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.removeDocument) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.removeDocument(request: request, headers: headers)
    }

    @available(iOS 13, *)
    public func pushPullChanges(request: Yorkie_V1_PushPullChangesRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_PushPullChangesResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.pushPullChanges(request: request, headers: headers)
    }

    public func watchDocument(headers: Connect.Headers = [:], onResult: @escaping @Sendable (Connect.StreamResult<Yorkie_V1_WatchDocumentResponse>) -> Void) -> any Connect.ServerOnlyStreamInterface<Yorkie_V1_WatchDocumentRequest> {
        return self.rpcClient.watchDocument(headers: headers, onResult: onResult)
    }

    @available(iOS 13, *)
    public func broadcast(request: Yorkie_V1_BroadcastRequest, headers: Connect.Headers = [:]) async -> ResponseMessage<Yorkie_V1_BroadcastResponse> {
        if self.isMockingEnabled, let error = getMockError(for: YorkieServiceClient.Metadata.Methods.broadcast) {
            return .init(result: .failure(error))
        }
        return await self.rpcClient.broadcast(request: request, headers: headers)
    }
}

extension YorkieService {
    /**
     * `setMockError` sets a mock error for a specific method.
     * If mocking is enabled, this error will be returned the next time the
     * corresponding method is called.
     */
    public func setMockError(for method: Connect.MethodSpec, error: ConnectError) {
        self.mockErrors[method.name] = error
    }

    /**
     * `getMockError` retrieves and removes the mock error for a specific method.
     */
    private func getMockError(for method: Connect.MethodSpec) -> ConnectError? {
        guard self.isMockingEnabled else { return nil }
        return self.mockErrors.removeValue(forKey: method.name)
    }
}
