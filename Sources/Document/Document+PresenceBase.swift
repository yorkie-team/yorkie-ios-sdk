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

/// What a ``Document`` knows about the server's presence-patch support and about the presence base
/// the server holds for this client (yorkie-js-sdk#1477).
struct PresenceBaseState: Equatable {
    /// Whether the last pack the server returned advertised the `presence-patch` capability.
    /// Absence means unsupported, so it starts `false` and an old server, which advertises nothing,
    /// keeps it `false`.
    var patchable = false

    /// Whether the server has a base to fold a patch into: a full put has been recorded since the
    /// last thing that left it without one. Attach, a `clear`, and a restore from offline
    /// persistence all clear it; recording a put sets it.
    var baseSent = false

    /// Whether a presence patch is outstanding: the last presence change recorded was a patch, or one
    /// is still queued. It decides whether a reply that has dropped the capability needs healing: an
    /// old server does not reject a patch, it stores it as an empty presence for the client, so peers
    /// are left wrong until a full put lands.
    var patchSent = false
}

/// Sending the presence as a patch when the server advertises `presence-patch`. Kept in its own
/// file, apart from the `Document` class body, to stay within this project's `type_body_length`
/// budget.
extension Document {
    /// Returns whether the next presence update may be recorded as a patch rather than a full put.
    ///
    /// Both halves are required: the server has to have advertised `presence-patch` on the pack it
    /// last returned, and it has to be holding a base of ours to fold the patch into.
    func canPatchPresence() -> Bool {
        self.presenceBase.patchable && self.presenceBase.baseSent
    }

    /// Takes the `presence-patch` capability from a pack the server returned and reports whether the
    /// presence now has to be healed with a full put.
    ///
    /// Absence means unsupported, so a reply from an old server during a rolling upgrade turns
    /// patching off. An old server does not reject a patch -- it stores it as an empty presence for
    /// the client -- so once a patch has been recorded, a server that does not advertise the
    /// capability leaves the peers holding an empty presence until a full put lands.
    ///
    /// The test is only whether a patch is outstanding, not whether patching was on a moment ago: a
    /// patch queued across a restore was minted in an earlier session, so there is no "was
    /// patchable" to compare against.
    ///
    /// It does not heal itself: the caller decides when the put is minted, so it lands against the
    /// state the pack left behind rather than mid-application.
    ///
    /// - Parameter pack: The pack the server returned.
    /// - Returns: Whether ``healPresenceBase(needed:)`` is owed.
    func learnPresenceCapability(_ pack: ChangePack) -> Bool {
        self.presenceBase.patchable = pack.hasCapability(presencePatchCapability)
        return !self.presenceBase.patchable && self.presenceBase.patchSent
    }

    /// Re-sends the whole presence as a put, after a patch that a server without the capability may
    /// have stored as empty.
    ///
    /// Minting it is a side effect of applying a pack rather than something the caller asked for, so
    /// it defers to ``isMintable`` instead of throwing `errRefused` out of an unrelated API: inside
    /// the re-anchor window ``discardLocalChanges()`` opens, and on a removed document, the heal is
    /// dropped. Nothing is lost by that -- a re-anchor re-sends the presence as a put of its own, and
    /// a removed document has no peers left to tell. A failure is logged, never thrown, because this
    /// runs inside ``applyChangePack(_:)``.
    ///
    /// - Parameter needed: Whether ``learnPresenceCapability(_:)`` said a heal is owed. A heal that is
    ///   not owed is a no-op, which keeps the two call sites a single line each.
    func healPresenceBase(needed: Bool) {
        guard needed, self.status != .removed, self.isMintable else {
            return
        }

        // The encoded values go back through `setEncoded` as they are stored: decoding them to `Any`
        // and re-encoding would be lossy. The capability is off at this point, so it records a put.
        let encoded = self.getMyEncodedPresence() ?? [:]
        do {
            try self.update { _, presence in
                presence.setEncoded(encoded)
            }
        } catch {
            Logger.warning("[PP] d:\"\(self.getKey())\" could not heal the presence base: \(error)")
        }
    }

    /// Records what the given local change did to the base the server holds for this client, so the
    /// next update knows whether it may patch.
    ///
    /// - Parameter change: The change just appended to the queue.
    func trackPresenceBase(_ change: Change) {
        switch change.presenceChange {
        case .put:
            self.presenceBase.baseSent = true
            self.presenceBase.patchSent = false
        case .patch:
            self.presenceBase.patchSent = true
        case .clear:
            // A `clear` leaves the server with no base: the server treats a patch after one as
            // baseless, so the next presence change has to be a put.
            self.presenceBase.baseSent = false
            self.presenceBase.patchSent = false
        case nil:
            break
        }
    }

    /// Returns the presence-patch state to what a document rehydrated from offline persistence may
    /// assume. Every path that rebuilds the queue from persisted changes goes through it, so an
    /// in-place restore is left in the same state as the static `fromBytes`, and a re-anchor leaves
    /// all three flags down.
    ///
    /// The capability is unknown again -- it is learned from a returned pack, and none has landed in
    /// this session -- and the base is gone with it. A patch still queued counts as outstanding.
    /// Persistence writes a patch as the put it stands for (see `Converter.toPersistedChange`) and
    /// records that it was minted as a patch, which ``hasPendingPresencePatch()`` counts too: that
    /// patch may have been pushed before the restart and stored as empty by a server without the
    /// capability, and the restored put is deduplicated, so only a heal repairs it. The flag is
    /// derived from the queue, not assumed.
    func resetPresenceStateForRestore() {
        self.presenceBase.patchable = false
        self.presenceBase.baseSent = false
        self.presenceBase.patchSent = self.hasPendingPresencePatch()
    }

    /// Rewrites the earliest pending presence patch into a full put of the presence as of that
    /// change, leaving the later patches alone: the server folds them in order, so a put in front of
    /// them is the base they need. It answers `ErrPresenceBaseUnavailable`, where nothing in the
    /// rejected pack was stored and the whole pack is resent.
    func restorePresencePatches() {
        // The base is gone whether or not this pack carried a patch, so the next update has to send a
        // put as well. The rewrite below supplies it for the pack already queued.
        self.presenceBase.baseSent = false

        if self.rewriteFirstPendingPresencePatch() {
            self.presenceBase.baseSent = true
        }

        // The rewrite deliberately leaves the later patches alone, so the queue usually still holds
        // one. A patch is outstanding whenever it does, and clearing the flag regardless would tell
        // ``learnPresenceCapability(_:)`` there is nothing to heal -- exactly when a server without
        // the capability is about to store those patches as an empty presence.
        self.presenceBase.patchSent = self.hasPendingPresencePatch()
    }
}
