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

enum YorkieError: Error {
    case unexpected(message: String)
    case clientNotActivated(message: String)
    case clientNotFound(message: String)
    case unimplemented(message: String)
    case unsupported(message: String)

    case documentNotAttached(message: String)
    case documentNotDetached(message: String)
    case documentRemoved(message: String)

    case invalidObjectKey(message: String)
    case invalidArgument(message: String)

    case noSuchElement(message: String)
    case timeout(message: String)
    case rpcError(message: String)

    enum Code: String {
        // Ok is returned when the operation completed successfully.
        case ok

        // ErrClientNotActivated is returned when the client is not active.
        case errClientNotActivated = "ErrClientNotActivated"

        // ErrClientNotFound is returned when the client is not found.
        case errClientNotFound = "ErrClientNotFound"

        // ErrUnimplemented is returned when the operation is not implemented.
        case errUnimplemented = "ErrUnimplemented"

        // Unsupported is returned when the operation is not supported.
        case unsupported

        // ErrDocumentNotAttached is returned when the document is not attached.
        case errDocumentNotAttached = "ErrDocumentNotAttached"

        // ErrDocumentNotDetached is returned when the document is not detached.
        case errDocumentNotDetached = "ErrDocumentNotDetached"

        // ErrDocumentRemoved is returned when the document is removed.
        case errDocumentRemoved = "ErrDocumentRemoved"

        // InvalidObjectKey is returned when the object key is invalid.
        case errInvalidObjectKey = "ErrInvalidObjectKey"

        // ErrInvalidArgument is returned when the argument is invalid.
        case errInvalidArgument = "ErrInvalidArgument"
    }

    var code: YorkieError.Code? {
        switch self {
        case .clientNotActivated: return .errClientNotActivated
        case .clientNotFound: return .errClientNotFound
        case .unimplemented: return .errUnimplemented
        case .unsupported: return .unsupported
        case .documentNotAttached: return .errDocumentNotAttached
        case .documentNotDetached: return .errDocumentNotDetached
        case .documentRemoved: return .errDocumentRemoved
        case .invalidObjectKey: return .errInvalidObjectKey
        case .invalidArgument: return .errInvalidArgument
        default:
            return nil
        }
    }
}

/**
 * `errorCodeOf` returns the error code of the given connect error.
 */
func errorCodeOf(error: ConnectError) -> String {
    // NOTE(hackerwins): Currently, we only use the first detail to represent the
    // error code.
    let infos: [ErrorInfo] = error.unpackedDetails()
    for info in infos {
        return info.metadata["code"] ?? ""
    }
    return ""
}

func toYorkieErrorCode(from error: Error) -> YorkieError.Code? {
    guard let yorkieError = error as? YorkieError, let code = yorkieError.code else {
        return nil
    }
    return code
}

func connectError(from code: Code) -> ConnectError {
    return ConnectError.from(code: code, headers: nil, trailers: nil, source: nil)
}
