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
struct TodomvcApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase

    @State var key = Constant.documentKey

    var body: some Scene {
        WindowGroup {
            NavigationView {
                VStack {
                    Text("Input document key or use the default")
                    TextField(text: self.$key) {
                        Text("Input documentKey")
                    }

                    NavigationLink(destination: ContentView()) {
                        Text("Go")
                    }
                }
                .padding()
            }
            .navigationViewStyle(.stack)
        }.onChange(of: self.scenePhase) { newPhase in
            Log.log("[ChangePhase] -> \(newPhase)", level: .debug)
        }
        .onChange(of: self.key) { newValue in
            Constant.documentKey = newValue
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }
}
