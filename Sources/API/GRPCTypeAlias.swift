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

// Use a Swift typealias to remap the type names of Protobuf locally
// Swift Protobuf Guide: https://github.com/apple/swift-protobuf/blob/main/Documentation/API.md#generated-struct-name
import Foundation
import Connect

typealias YorkieServiceClient = Yorkie_V1_YorkieServiceClient
typealias YorkieServerStream = Connect.ServerOnlyStreamInterface<WatchDocumentRequest>

typealias ActivateClientRequest = Yorkie_V1_ActivateClientRequest
typealias ActivateClientResponse = Yorkie_V1_ActivateClientResponse
typealias DeactivateClientRequest = Yorkie_V1_DeactivateClientRequest
typealias DeactivateClientResponse = Yorkie_V1_DeactivateClientResponse
typealias AttachDocumentRequest = Yorkie_V1_AttachDocumentRequest
typealias AttachDocumentResponse = Yorkie_V1_AttachDocumentResponse
typealias DetachDocumentRequest = Yorkie_V1_DetachDocumentRequest
typealias DetachDocumentResponse = Yorkie_V1_DetachDocumentResponse
typealias PushPullChangeRequest = Yorkie_V1_PushPullChangesRequest
typealias PushPullChangeResponse = Yorkie_V1_PushPullChangesResponse
typealias WatchDocumentRequest = Yorkie_V1_WatchDocumentRequest
typealias WatchDocumentResponse = Yorkie_V1_WatchDocumentResponse
typealias RemoveDocumentRequest = Yorkie_V1_RemoveDocumentRequest
typealias RemoveDocumentResponse = Yorkie_V1_RemoveDocumentResponse
typealias BroadcastRequest = Yorkie_V1_BroadcastRequest
typealias BroadcastResponse = Yorkie_V1_BroadcastResponse

typealias PbChange = Yorkie_V1_Change
typealias PbChangeID = Yorkie_V1_ChangeID
typealias PbChangePack = Yorkie_V1_ChangePack
typealias PbCheckpoint = Yorkie_V1_Checkpoint
typealias PbPresence = Yorkie_V1_Presence
typealias PbPresenceChange = Yorkie_V1_PresenceChange
typealias PbJSONElement = Yorkie_V1_JSONElement
typealias PbJSONElementSimple = Yorkie_V1_JSONElementSimple
typealias PbOperation = Yorkie_V1_Operation
typealias PbRGANode = Yorkie_V1_RGANode
typealias PbRHTNode = Yorkie_V1_RHTNode
typealias PbTextNode = Yorkie_V1_TextNode
typealias PbTextNodeID = Yorkie_V1_TextNodeID
typealias PbTimeTicket = Yorkie_V1_TimeTicket
typealias PbValueType = Yorkie_V1_ValueType
typealias PbTextNodePos = Yorkie_V1_TextNodePos
typealias PbNodeAttr = Yorkie_V1_NodeAttr
typealias PbTreeNode = Yorkie_V1_TreeNode
typealias PbTreePos = Yorkie_V1_TreePos
typealias PbTreeNodes = Yorkie_V1_TreeNodes
typealias PbSnapshot = Yorkie_V1_Snapshot
typealias PbTreeNodeID = Yorkie_V1_TreeNodeID
typealias PbVersionVector = Yorkie_V1_VersionVector

typealias ErrorInfo = Google_Rpc_ErrorInfo
