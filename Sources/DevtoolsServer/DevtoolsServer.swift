/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
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
import Network
import Yorkie

/// `DevtoolsServerError` describes why the inspector server could not start.
public enum DevtoolsServerError: Error {
    case invalidPort(UInt16)
    case devtoolsDisabled
}

/// `DevtoolsServer` serves a live, browser-based inspector for a ``Document``.
///
/// It runs a small loopback/LAN HTTP server (via `Network.framework`, no extra
/// dependencies) that serves the viewer page at `/` and the current event buffer
/// as JSON at `/events`. A browser opens the page and polls `/events`, so changes
/// stream in **live** as the document is edited — no export step.
///
/// This is a **debug-only** tool. It binds beyond loopback (so a browser on
/// another machine on the same network can connect to a physical device), so only
/// start it in debug builds, and only on documents created with
/// `enableDevtools: true`.
@MainActor
public final class DevtoolsServer {
    /// The TCP port the server listens on.
    public let port: UInt16

    /// Whether the server is currently listening.
    public private(set) var isRunning = false

    private let document: Document
    private var listener: NWListener?
    private var recorder: DevtoolsRecorder?
    private let store = SnapshotStore()
    private let queue = DispatchQueue(label: "dev.yorkie.devtools.server")

    public init(document: Document, port: UInt16 = 9123) {
        self.document = document
        self.port = port
    }

    deinit {
        self.listener?.cancel()
    }

    /// Starts listening and begins mirroring the document's recording.
    ///
    /// - Throws: ``DevtoolsServerError/devtoolsDisabled`` if the document was not
    ///   created with `enableDevtools: true`, or ``DevtoolsServerError/invalidPort(_:)``.
    public func start() throws {
        guard !self.isRunning else {
            return
        }
        guard let recorder = self.document.attachDevtoolsRecorder() else {
            throw DevtoolsServerError.devtoolsDisabled
        }
        self.recorder = recorder
        self.refreshSnapshot()
        recorder.onUpdate = { [weak self] in self?.refreshSnapshot() }

        guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
            throw DevtoolsServerError.invalidPort(self.port)
        }

        let html = Self.viewerHTML
        let store = self.store
        let queue = self.queue

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { connection in
            serveConnection(connection, store: store, html: html, queue: queue)
        }
        listener.start(queue: queue)
        self.listener = listener
        self.isRunning = true
    }

    /// Stops listening and detaches from the recorder.
    public func stop() {
        self.recorder?.onUpdate = nil
        self.listener?.cancel()
        self.listener = nil
        self.isRunning = false
    }

    /// The URLs at which the inspector is reachable: always `localhost`, plus any
    /// LAN IPv4 addresses (for connecting from a browser to a physical device).
    public func urls() -> [String] {
        var result = ["http://localhost:\(self.port)"]
        for ip in Self.lanIPv4Addresses() {
            result.append("http://\(ip):\(self.port)")
        }
        return result
    }

    private func refreshSnapshot() {
        self.store.set(self.recorder?.exportJSON(pretty: false) ?? Data("[]".utf8))
    }

    // MARK: - Resources

    private static let viewerHTML: Data = {
        if let url = Bundle.module.url(forResource: "viewer", withExtension: "html"),
           let data = try? Data(contentsOf: url)
        {
            return data
        }
        return Data("<!doctype html><meta charset=utf-8><body style=\"font-family:sans-serif\">viewer.html resource missing from YorkieDevtoolsServer bundle.</body>".utf8)
    }()

    private static func lanIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return addresses
        }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let addr = current.pointee.ifa_addr,
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.isEmpty, !addresses.contains(ip) {
                    addresses.append(ip)
                }
            }
        }
        return addresses
    }
}

/// `SnapshotStore` holds the latest serialised recording behind a lock so the
/// network queue can read it without touching main-actor state.
private final class SnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data("[]".utf8)

    func set(_ newData: Data) {
        self.lock.lock()
        self.data = newData
        self.lock.unlock()
    }

    func get() -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.data
    }
}

/// Handles a single HTTP request: routes `/events` to the live JSON buffer and
/// everything else to the viewer page, then closes the connection.
private func serveConnection(_ connection: NWConnection, store: SnapshotStore, html: Data, queue: DispatchQueue) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        var path = "/"
        if let data, let request = String(data: data, encoding: .utf8) {
            let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(request)
            let parts = firstLine.split(separator: " ")
            if parts.count >= 2 {
                path = String(parts[1])
            }
        }

        let contentType: String
        let body: Data
        if path.hasPrefix("/events") {
            contentType = "application/json"
            body = store.get()
        } else {
            contentType = "text/html; charset=utf-8"
            body = html
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
