/*
 * Copyright 2023 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
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

import Foundation
import GRPC
import NIOCore

class AuthClientInterceptor<Request, Response>: ClientInterceptor<Request, Response> {
    let apiKey: String?
    let token: String?
    let docKey: String?

    init(apiKey: String? = nil, token: String? = nil, docKey: String? = nil) {
        self.apiKey = apiKey
        self.token = token
        self.docKey = docKey
    }

    override func send(_ part: GRPCClientRequestPart<Request>, promise: EventLoopPromise<Void>?, context: ClientInterceptorContext<Request, Response>) {
        var part = part

        switch part {
        case .metadata(var header):
            if let apiKey {
                header.add(name: "x-api-key", value: apiKey)

                var shardKey = "\(apiKey)"

                if let docKey = self.docKey, docKey.isEmpty == false {
                    shardKey += "/\(docKey)"
                }

                header.add(name: "x-shard-key", value: shardKey)
            }

            if let token {
                header.add(name: "authorization", value: token)
            }

            header.add(name: "x-yorkie-user-agent", value: "yorkie-ios-sdk/\(yorkieVersion)")
            part = .metadata(header)
        default:
            break
        }

        context.send(part, promise: promise)
    }
}

final class AuthClientInterceptors: YorkieServiceClientInterceptorFactoryProtocol {
    let apiKey: String?
    let token: String?
    let docKey: String?

    init(apiKey: String? = nil, token: String? = nil, docKey: String? = nil) {
        self.apiKey = apiKey
        self.token = token
        self.docKey = docKey
    }

    func docKeyChangedInterceptors(_ docKey: String?) -> AuthClientInterceptors {
        AuthClientInterceptors(apiKey: self.apiKey, token: self.token, docKey: docKey)
    }

    func makeActivateClientInterceptors() -> [GRPC.ClientInterceptor<ActivateClientRequest, ActivateClientResponse>] {
        [AuthClientInterceptor<ActivateClientRequest, ActivateClientResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeDeactivateClientInterceptors() -> [GRPC.ClientInterceptor<DeactivateClientRequest, DeactivateClientResponse>] {
        [AuthClientInterceptor<DeactivateClientRequest, DeactivateClientResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeUpdatePresenceInterceptors() -> [GRPC.ClientInterceptor<UpdatePresenceRequest, UpdatePresenceResponse>] {
        [AuthClientInterceptor<UpdatePresenceRequest, UpdatePresenceResponse>(apiKey: self.apiKey, token: self.token, docKey: self.docKey)]
    }

    func makeAttachDocumentInterceptors() -> [GRPC.ClientInterceptor<AttachDocumentRequest, AttachDocumentResponse>] {
        [AuthClientInterceptor<AttachDocumentRequest, AttachDocumentResponse>(apiKey: self.apiKey, token: self.token, docKey: self.docKey)]
    }

    func makeDetachDocumentInterceptors() -> [GRPC.ClientInterceptor<DetachDocumentRequest, DetachDocumentResponse>] {
        [AuthClientInterceptor<DetachDocumentRequest, DetachDocumentResponse>(apiKey: self.apiKey, token: self.token, docKey: self.docKey)]
    }

    func makeWatchDocumentInterceptors() -> [GRPC.ClientInterceptor<WatchDocumentRequest, WatchDocumentResponse>] {
        [AuthClientInterceptor<WatchDocumentRequest, WatchDocumentResponse>(apiKey: self.apiKey, token: self.token, docKey: self.docKey)]
    }

    func makeRemoveDocumentInterceptors() -> [GRPC.ClientInterceptor<Yorkie_V1_RemoveDocumentRequest, Yorkie_V1_RemoveDocumentResponse>] {
        [AuthClientInterceptor<RemoveDocumentRequest, RemoveDocumentResponse>(apiKey: self.apiKey, token: self.token, docKey: self.docKey)]
    }

    func makePushPullChangesInterceptors() -> [GRPC.ClientInterceptor<Yorkie_V1_PushPullChangesRequest, Yorkie_V1_PushPullChangesResponse>] {
        [AuthClientInterceptor<PushPullChangeRequest, PushPullChangeResponse>(apiKey: self.apiKey, token: self.token, docKey: self.docKey)]
    }
}
