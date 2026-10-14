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

import Connect
import Foundation

extension Client {
    /// The server codes for a push refused on its content rather than on conditions: the same pack
    /// re-sent is measured against the same gate and refused again.
    ///
    /// Kept in one place because three sites read it: the sync loop's parking of the rejected
    /// attachment, the ``WriteRejectedEvent``, and `handleConnectError`'s non-retry answer.
    static let unretryableWriteCodes: [YorkieError.Code] = [
        .errDocumentSizeExceedsLimit,
        .errChangeTooLarge
    ]

    /// Returns the write-rejection code carried by `error`, or `nil` when it is not one.
    ///
    /// A `ResourceExhausted` error without a Yorkie code is not a rejection: it stays retryable.
    static func writeRejectionCode(of error: Error?) -> WriteRejectedValue.Code? {
        guard let connectError = error as? ConnectError,
              let code = YorkieError.Code(rawValue: errorCodeOf(error: connectError)),
              self.unretryableWriteCodes.contains(code)
        else {
            return nil
        }

        switch code {
        case .errDocumentSizeExceedsLimit:
            return .documentSizeExceedsLimit
        case .errChangeTooLarge:
            return .changeTooLarge
        default:
            return nil
        }
    }

    /// Publishes a ``WriteRejectedEvent`` on the attachment's document when `error` is a
    /// rejection the server will repeat.
    func publishWriteRejectedIfNeeded(error: Error?, attachment: Attachment<Document>) {
        guard let code = Self.writeRejectionCode(of: error), let connectError = error as? ConnectError else {
            return
        }

        attachment.resource.publishWriteRejectedEvent(
            code: code,
            reason: connectError.message ?? "",
            method: "PushPull"
        )
    }

    /// Syncs one attachment for the realtime loop, parking it instead of failing the loop when the
    /// server rejects its write.
    ///
    /// A rejected write is this document's problem, not the client's: the attachment is marked and
    /// the error swallowed here, so it never reaches `doSyncLoop`. Letting it through would take
    /// `handleConnectError` down the non-retry path and stop the loop for every other attached
    /// document. `syncInternal` has already published ``WriteRejectedEvent`` on the document.
    /// Any other error propagates.
    func syncParkingWriteRejection(_ attachment: Attachment<Document>, _ syncMode: SyncMode) async throws {
        do {
            try await self.syncInternal(attachment, syncMode)
        } catch {
            guard Self.writeRejectionCode(of: error) != nil else {
                throw error
            }
            attachment.markWriteRejected()
        }
    }
}
