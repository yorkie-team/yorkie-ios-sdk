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

/// `DevtoolsEventSource` names the source of a devtools message.
///
/// Mirrors `EventSourceDevPanel` / `EventSourceSDK` in
/// `yorkie-js-sdk/packages/sdk/src/devtools/protocol.ts` so that recordings
/// exported from this SDK are interchangeable with the JS devtools format.
enum DevtoolsEventSource {
    /// Source representing messages from the devtools panel.
    static let devPanel = "yorkie-devtools-panel"
    /// Source representing messages from the SDK.
    static let sdk = "yorkie-devtools-sdk"
}

/// `DevtoolsMessageType` enumerates the SDK-to-panel message kinds.
///
/// Mirrors the `msg` discriminator of `SDKToPanelMessage` in the JS devtools
/// protocol. Only the subset that the iOS recorder produces is modelled; the
/// `postMessage` transport itself is browser-specific and intentionally absent.
enum DevtoolsMessageType: String {
    /// Synchronises the entire current event log.
    case fullSync = "doc::sync::full"
    /// Sends a single batch whenever the document changes.
    case partialSync = "doc::sync::partial"
    /// Announces that a document is available for the panel to watch.
    case available = "doc::available"
}

/// `DevtoolsStatus` is the connection status of the devtools panel.
///
/// Mirrors `DevtoolsStatus` in the JS devtools integration.
enum DevtoolsStatus: String {
    case disconnected
    case connected
    case synced
}
