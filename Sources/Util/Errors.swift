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
 * `YorkieError` is an error returned by a Yorkie operation.
 */
struct YorkieError: Error, CustomStringConvertible {
    let code: Code
    let message: String

    var description: String {
        return "[code=\(self.code.rawValue)]: \(self.message)"
    }

    enum Code: String {
        /// Ok is returned when the operation completed successfully.
        case ok

        /// ErrClientNotActivated is returned when the client is not active.
        case errClientNotActivated = "ErrClientNotActivated"

        /// ErrClientNotFound is returned when the client is not found.
        case errClientNotFound = "ErrClientNotFound"

        /// ErrUnimplemented is returned when the operation is not implemented.
        case errUnimplemented = "ErrUnimplemented"

        /// ErrInvalidType is returned when the type is invalid.
        case errInvalidType = "ErrInvalidType"

        /// ErrDummy is used to verify errors for testing purposes.
        case errDummy = "ErrDummy"

        /// ErrDocumentNotAttached is returned when the document is not attached.
        case errDocumentNotAttached = "ErrDocumentNotAttached"

        /// ErrDocumentNotDetached is returned when the document is not detached.
        case errDocumentNotDetached = "ErrDocumentNotDetached"

        /// ErrDocumentRemoved is returned when the document is removed.
        case errDocumentRemoved = "ErrDocumentRemoved"

        /// ErrDocumentSizeExceedsLimit is returned when the document size exceeds the limit.
        case errDocumentSizeExceedsLimit = "ErrDocumentSizeExceedsLimit"

        /// ErrDocumentSchemaValidationFailed is returned when the document schema validation failed.
        case errDocumentSchemaValidationFailed = "ErrDocumentSchemaValidationFailed"

        /// ErrInvalidObjectKey is returned when the object key is invalid.
        case errInvalidObjectKey = "ErrInvalidObjectKey"

        /// ErrInvalidArgument is returned when the argument is invalid.
        case errInvalidArgument = "ErrInvalidArgument"

        /// ErrNotInitialized is returned when required initialization has not been completed.
        case errNotInitialized = "ErrNotInitialized"

        /// ErrNotReady is returned when execution of following actions is not ready.
        case errNotReady = "ErrNotReady"

        /// ErrRefused is returned when the execution is rejected.
        case errRefused = "ErrRefused"

        /// ErrUnexpected is returned when an unexpected error occurred (iOS only)
        case errUnexpected = "ErrUnexpected"

        /// ErrRPC is returned when an error occurred in the RPC Request
        case errRPC = "ErrRPC"

        // ErrPermissionDenied is returned when the authorization webhook denies the request.
        case errPermissionDenied = "ErrPermissionDenied"

        // ErrUnauthenticated is returned when the request does not have valid authentication credentials.
        case errUnauthenticated = "ErrUnauthenticated"

        // ErrTooManyAttachments is returned when the number of attachments exceeds the limit.
        case errTooManyAttachments = "ErrTooManyAttachments"

        // ErrTooManySubscribers is returned when the number of subscribers exceeds the limit.
        case errTooManySubscribers = "ErrTooManySubscribers"
    }
}

/**
 * `errorMetadataOf` returns the error metadata of the given connect error.
 */
func errorMetadataOf(error: ConnectError) -> [String: String] {
    // NOTE(hackerwins): Currently, we only use the first detail to represent the
    // error code.
    let infos: [ErrorInfo] = error.unpackedDetails()
    return infos.first?.metadata ?? [:]
}

/**
 * `errorCodeOf` returns the error code of the given connect error.
 */
func errorCodeOf(error: ConnectError) -> String {
    return errorMetadataOf(error: error)["code"] ?? ""
}

/**
 * `isErrorCode` checks if the error is a ConnectError with the given error code.
 */
func isErrorCode(_ error: Error, _ code: String) -> Bool {
    guard let connectError = error as? ConnectError else {
        return false
    }
    return errorCodeOf(error: connectError) == code
}

func toYorkieErrorCode(from error: Error) -> YorkieError.Code? {
    guard let yorkieError = error as? YorkieError else {
        return nil
    }
    return yorkieError.code
}

func connectError(from code: Code) -> ConnectError {
    return ConnectError.from(code: code, headers: nil, trailers: nil, source: nil)
}
