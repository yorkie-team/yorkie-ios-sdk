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

class ActivateClientInterceptor<Request, Response>: ClientInterceptor<Request, Response> {
    let apiKey: String?
    let token: String?

    init(apiKey: String? = nil, token: String? = nil) {
        self.apiKey = apiKey
        self.token = token
    }

    override func send(_ part: GRPCClientRequestPart<Request>, promise: EventLoopPromise<Void>?, context: ClientInterceptorContext<Request, Response>) {
        var part = part

        switch part {
        case .metadata(var header):
            if let apiKey {
                header.add(name: "x-api-key", value: apiKey)
            }

            if let token {
                header.add(name: "authorization", value: token)
            }

            part = .metadata(header)
        default:
            break
        }

        context.send(part, promise: promise)
    }
}

final class AuthInterceptors: InterceptorFactoryProtocol {
    let apiKey: String?
    let token: String?

    init(apiKey: String? = nil, token: String? = nil) {
        self.apiKey = apiKey
        self.token = token
    }

    func makeActivateClientInterceptors() -> [GRPC.ClientInterceptor<ActivateClientRequest, ActivateClientResponse>] {
        [ActivateClientInterceptor<ActivateClientRequest, ActivateClientResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeDeactivateClientInterceptors() -> [GRPC.ClientInterceptor<DeactivateClientRequest, DeactivateClientResponse>] {
        [ActivateClientInterceptor<DeactivateClientRequest, DeactivateClientResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeUpdatePresenceInterceptors() -> [GRPC.ClientInterceptor<UpdatePresenceRequest, UpdatePresenceResponse>] {
        [ActivateClientInterceptor<UpdatePresenceRequest, UpdatePresenceResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeAttachDocumentInterceptors() -> [GRPC.ClientInterceptor<AttachDocumentRequest, AttachDocumentResponse>] {
        [ActivateClientInterceptor<AttachDocumentRequest, AttachDocumentResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeDetachDocumentInterceptors() -> [GRPC.ClientInterceptor<DetachDocumentRequest, DetachDocumentResponse>] {
        [ActivateClientInterceptor<DetachDocumentRequest, DetachDocumentResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makeWatchDocumentsInterceptors() -> [GRPC.ClientInterceptor<WatchDocumentsRequest, WatchDocumentsResponse>] {
        [ActivateClientInterceptor<WatchDocumentsRequest, WatchDocumentsResponse>(apiKey: self.apiKey, token: self.token)]
    }

    func makePushPullInterceptors() -> [GRPC.ClientInterceptor<PushPullRequest, PushPullResponse>] {
        [ActivateClientInterceptor<PushPullRequest, PushPullResponse>(apiKey: self.apiKey, token: self.token)]
    }
}
