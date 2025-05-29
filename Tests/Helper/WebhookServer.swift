/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

import Foundation
import NIO
import NIOHTTP1

final class WebhookServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private let port: Int

    init(port: Int = 3004) {
        self.port = port
    }

    func start() throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(WebhookRequestHandler())
                }
            }

            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        self.channel = try bootstrap.bind(host: "127.0.0.1", port: self.port).wait()
        print("✅ Webhook server started on port \(self.port)")
    }

    func stop() {
        try? self.channel?.close().wait()
        try? self.group.syncShutdownGracefully()
        print("🛑 Webhook server stopped")
    }

    var authWebhookUrl: String {
        return "http://127.0.0.1:\(self.port)/auth-webhook"
    }
}

final class WebhookRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var buffer: ByteBuffer?
    private var headers: HTTPHeaders?
    private var keepAlive = false
    private var uri: String?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)

        switch reqPart {
        case .head(let requestHead):
            self.uri = requestHead.uri
            self.headers = requestHead.headers
            self.buffer = context.channel.allocator.buffer(capacity: 0)
            self.keepAlive = requestHead.isKeepAlive

        case .body(var byteBuffer):
            self.buffer?.writeBuffer(&byteBuffer)

        case .end:
            guard self.uri == "/auth-webhook",
                  let buffer = self.buffer,
                  let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes)
            else {
                self.sendResponse(context: context, status: .badRequest, body: #"{"allowed": false, "reason": "invalid body"}"#)
                return
            }

            let bodyData = Data(bytes)
            guard let json = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any],
                  let token = json["token"] as? String
            else {
                self.sendResponse(context: context, status: .unauthorized, body: #"{"allowed": false, "reason": "invalid token"}"#)
                return
            }

            if token.hasPrefix("token") {
                let parts = token.split(separator: "-")
                if parts.count >= 2, let expiry = Double(parts[1]), expiry < Date().timeIntervalSince1970 {
                    self.sendResponse(context: context, status: .unauthorized, body: #"{"allowed": false, "reason": "expired token"}"#)
                    return
                }
                self.sendResponse(context: context, status: .ok, body: #"{"allowed": true}"#)
            } else if token == "not-allowed-token" {
                self.sendResponse(context: context, status: .forbidden, body: #"{"allowed": false}"#)
            } else {
                self.sendResponse(context: context, status: .unauthorized, body: #"{"allowed": false, "reason": "invalid token"}"#)
            }
        }
    }

    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        context.write(self.wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        let end = self.keepAlive ? HTTPServerResponsePart.end(nil) : .end(nil)
        context.writeAndFlush(self.wrapOutboundOut(end), promise: nil)
    }
}
