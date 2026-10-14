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

/// A value shared between a test body and seam closures, which are not main-actor bound.
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        self.stored = value
    }

    var value: T {
        get { self.lock.withLock { self.stored } }
        set { self.lock.withLock { self.stored = newValue } }
    }
}

/// A latch a test closes around a seam closure: `wait()` suspends until `open()` is called.
///
/// Opening before anyone waits is remembered, so the order of `open()` and `wait()` never races.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self.isOpen {
                self.lock.unlock()
                continuation.resume()
            } else {
                self.waiter = continuation
                self.lock.unlock()
            }
        }
    }

    func open() {
        self.lock.lock()
        self.isOpen = true
        let pending = self.waiter
        self.waiter = nil
        self.lock.unlock()
        pending?.resume()
    }
}
