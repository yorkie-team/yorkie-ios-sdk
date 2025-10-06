/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

import SwiftUI

@main
struct SimutaneousCurcorsApp: App {
    @State var path = NavigationPath()
    @State var name = ""
    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                VStack {
                    Text("Welcome")
                        .font(.headline)
                    TextField("Input name:", text: $name)
                    NavigationLink("Enter room") {
                        ContentView(name: name)
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}
