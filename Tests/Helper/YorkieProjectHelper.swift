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

public struct YorkieProjectContext {
    public let rpcAddress: String
    public let adminToken: String
    public let publicKey: String
    public let secretKey: String
    public let projectID: String
}

enum YorkieProjectError: Error {
    case invalidResponse([String: Any])
    case missingToken
    case invalidProjectResponse([String: Any])
}

public enum YorkieProjectHelper {
    public static func initializeProject(
        rpcAddress: String,
        username: String,
        password: String,
        webhookURL: String,
        webhookMethods: [String] = [],
        projectName: String = "auth-webhook-\(Int(Date().timeIntervalSince1970))"
    ) async throws -> YorkieProjectContext {
        let token = try await logIn(rpcAddress: rpcAddress, username: username, password: password)

        let (projectID, publicKey, secretKey) = try await createProject(rpcAddress: rpcAddress, token: token, name: projectName)

        try await updateProjectWebhook(rpcAddress: rpcAddress, token: token, projectID: projectID, webhookURL: webhookURL, webhookMethods: webhookMethods)

        return YorkieProjectContext(
            rpcAddress: rpcAddress,
            adminToken: token,
            publicKey: publicKey,
            secretKey: secretKey,
            projectID: projectID
        )
    }

    public static func logIn(
        rpcAddress: String,
        username: String,
        password: String
    ) async throws -> String {
        let url = URL(string: "\(rpcAddress)/yorkie.v1.AdminService/LogIn")!
        let body = ["username": username, "password": password]
        let data = try await postJSON(to: url, body: body)
        guard let token = data["token"] as? String else {
            throw YorkieProjectError.missingToken
        }
        return token
    }

    public static func createProject(
        rpcAddress: String,
        token: String,
        name: String
    ) async throws -> (id: String, publicKey: String, secretKey: String) {
        let url = URL(string: "\(rpcAddress)/yorkie.v1.AdminService/CreateProject")!
        let body = ["name": name]
        let headers = ["Authorization": "Bearer " + token]
        let responseJSON = try await postJSON(to: url, body: body, headers: headers)

        guard let project = responseJSON["project"] as? [String: Any],
              let id = project["id"] as? String,
              let publicKey = project["publicKey"] as? String,
              let secretKey = project["secretKey"] as? String
        else {
            throw YorkieProjectError.invalidProjectResponse(responseJSON)
        }

        return (id: id, publicKey: publicKey, secretKey)
    }

    @discardableResult
    public static func updateProjectWebhook(rpcAddress: String,
                                            token: String,
                                            projectID: String,
                                            webhookURL: String,
                                            webhookMethods: [String] = [],
                                            customFields: [String: Any] = [:]) async throws -> [String: Any]
    {
        let url = URL(string: "\(rpcAddress)/yorkie.v1.AdminService/UpdateProject")!

        var fields: [String: Any] = [
            "auth_webhook_url": webhookURL
        ]

        for field in customFields {
            fields[field.key] = field.value
        }

        if !webhookMethods.isEmpty {
            fields["auth_webhook_methods"] = [
                "methods": webhookMethods
            ]
        }

        let body: [String: Any] = [
            "id": projectID,
            "fields": fields
        ]

        let headers = ["Authorization": "Bearer " + token]
        return try await self.postJSON(to: url, body: body, headers: headers)
    }

    public static func getProject(rpcAddress: String, token: String, projectName: String) async throws -> [String: Any] {
        let url = URL(string: "\(rpcAddress)/yorkie.v1.AdminService/GetProject")!
        let body = ["name": projectName]

        let headers = ["Authorization": "Bearer " + token]
        return try await self.postJSON(to: url, body: body, headers: headers)
    }

    private static func postJSON(
        to url: URL,
        body: [String: Any],
        headers: [String: String] = [:]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let responseJSON = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]

        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
            throw YorkieProjectError.invalidResponse(responseJSON)
        }

        return responseJSON
    }
}

extension YorkieProjectHelper {
    @discardableResult
    static func createSchema(
        rpcAddress: String,
        date: String,
        projectApiKey: String,
        projectSecretKey: String
    ) async throws -> [String: Any] {
        var result = [String: Any]()
        let schema1Body: [String: Any] = [
            // "projectName": "default",
            "schemaName": "schema1-" + date,
            "schemaVersion": 1,
            "schemaBody": "type Document = {title: string;};",
            "rules": [
                ["path": "$.title", "type": "string"]
            ]
        ]

        let url = URL(string: "\(rpcAddress)/yorkie.v1.AdminService/CreateSchema")!
        let headers = ["Authorization": "API-Key \(projectSecretKey)"]
        let result1 = try await Self.postJSON(to: url, body: schema1Body, headers: headers)
        result["\("schema1-" + date)"] = result1

        let schema2Body: [String: Any] = [
            "projectName": "default",
            "schemaName": "schema2-" + date,
            "schemaVersion": 1,
            "schemaBody": "type Document = {title: integer;};",
            "rules": [
                ["path": "$.title", "type": "integer"]
            ]
        ]
        let result2 = try await Self.postJSON(to: url, body: schema2Body, headers: headers)
        result["\("schema2-" + date)"] = result2
        return result
    }

    @discardableResult
    static func updateDocument(
        rpcAddress: String,
        updateBody: [String: Any],
        time: String,
        token: String
    ) async throws -> [String: Any] {
        let headers = ["Authorization": "API-Key " + token]
        let url = URL(string: "\(rpcAddress)/yorkie.v1.AdminService/UpdateDocument")!
        let result = try await Self.postJSON(to: url, body: updateBody, headers: headers)
        return result
    }
}
