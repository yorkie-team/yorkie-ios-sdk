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

struct ContentView: View {
    enum Status: String, Identifiable {
        var id: String { rawValue }

        case all = "All"
        case active = "Active"
        case completed = "Completed"
    }

    @StateObject private var viewModel = ContentViewModel()
    @State private var selectedStatus = Status.all
    @State private var showAdding = false
    @State private var showEditing = false
    @State private var selectedAll = false
    @State private var newTaskName = ""
    @State private var updatingModel: TodoModel? = nil
    @State var showSetting = false
    @State var key = ""
    @Environment(\.scenePhase) var scenePhase

    private let status: [Status] = [.all, .active, .completed]
    var body: some View {
        Group {
            switch self.viewModel.state {
            case .error(let error):
                errorView(error)
            case .loading:
                loadingView
            case .success:
                content
            }
        }
        .onChange(of: self.scenePhase) { newPhase in
            if newPhase == .active {
                self.viewModel.refreshDocument()
            }
        }
        .task {
            await self.viewModel.initializeClient()
        }
        .sheet(isPresented: self.$showSetting) {
            VStack {
                HStack {
                    Spacer()
                    Button {
                        self.showSetting = false
                    } label: {
                        Image(systemName: "xmark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    }
                }
                TextField(text: self.$key) {
                    Text("Input new key")
                }

                Button {
                    self.showSetting = false
                    self.viewModel.updateKeys(self.key)
                } label: {
                    Text("DONE")
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Views

extension ContentView {
    private var content: some View {
        VStack {
            self.headerView

            Spacer()

            ScrollView {
                let filteredModels: [TodoModel] = {
                    switch self.selectedStatus {
                    case .all:
                        return self.viewModel.models
                    case .active:
                        return self.viewModel.models.filter { !$0.completed }
                    case .completed:
                        return self.viewModel.models.filter { $0.completed }
                    }
                }()
                ForEach(filteredModels) { model in
                    HStack(spacing: 20) {
                        Button {
                            Log.log("[UI] -> task complete -> model.id: \(model.id), complete: \(!model.completed)", level: .info)
                            complete(model.id, complete: !model.completed)
                        } label: {
                            Image(systemName: model.completed ? "checkmark.circle" : "circle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 25, height: 25, alignment: .center)
                        }

                        Button {
                            self.updatingModel = model
                            self.showEditing = true
                            self.newTaskName = model.text
                        } label: {
                            Text("\(model.text)")
                                .strikethrough(model.completed)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()
                        Button {
                            Log.log("[UI] -> delete task -> model.id: \(model.id)", level: .info)
                            self.viewModel.deleteItem(model.id)
                        } label: {
                            Image(systemName: "delete.left")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20, alignment: .center)
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }

            Spacer()

            HStack {
                if self.viewModel.itemsLeft > 0 {
                    Text("\(self.viewModel.itemsLeft) item(s) left")
                } else {
                    Text("No items left")
                }

                if self.viewModel.models.contains(where: { $0.completed }) {
                    Button {
                        Log.log("[UI] -> remove all completed task", level: .info)
                        removeAllCompleted()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20, alignment: .center)
                                .padding(.trailing, 10)
                            Text("Clear all completed task!")
                        }
                        .foregroundStyle(Color.red)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red, lineWidth: 2)
                        )
                    }
                }
            }
        }
        .padding()
        .alert("Add New Todo", isPresented: self.$showAdding) {
            TextField("What needs to be done?", text: self.$newTaskName)
            HStack {
                Button {
                    addTask()
                    Log.log("[UI] -> Add new task: \(self.newTaskName)", level: .info)
                    self.showAdding = false
                } label: {
                    Text("Confirm")
                }
                .disabled(self.newTaskName.isEmpty)

                Button {
                    Log.log("[UI] -> Cancel Add new task: \(self.newTaskName)", level: .info)
                    self.showAdding = false
                } label: {
                    Text("Cancel")
                }
            }
        } message: {
            Text("Add new task to do here!")
        }
        .alert("Edit task name", isPresented: self.$showEditing) {
            TextField("What needs to be done?", text: self.$newTaskName)
            HStack {
                Button {
                    Log.log("[UI] -> Update task: \(self.newTaskName)", level: .info)
                    update()
                    self.showEditing = false
                } label: {
                    Text("Close")
                }

                Button {
                    Log.log("[UI] -> Cancel update task: \(self.newTaskName)", level: .info)
                    self.showEditing = false
                } label: {
                    Text("Cancel")
                }
            }
        } message: {
            Text("Add new task to do here!")
        }
        .navigationTitle("Todo")
        .onChange(of: self.viewModel.models) { newValue in
            Log.log("[UI] [VM] -> models: \(newValue)", level: .info)
            let hasChanged = newValue.contains(where: { $0.completed == false })
            self.selectedAll = !hasChanged
        }
        .onChange(of: self.selectedAll) { newValue in
            Log.log("[UI] [VM] -> selectedAll: \(newValue)", level: .info)
            if newValue == false {
                if self.viewModel.models.allSatisfy({ $0.completed == true }) {
                    self.viewModel.markAllAsComplete(newValue)
                }
                return
            }
            self.viewModel.markAllAsComplete(newValue)
        }
    }

    private func errorView(_ error: TDError) -> some View {
        Text("Error occur: \(error.localizedDescription)")
    }

    private var loadingView: some View {
        ProgressView()
    }

    var headerView: some View {
        VStack {
            HStack {
                Spacer()
                Text(self.viewModel.appVersion)
            }
            HStack {
                Picker("", selection: self.$selectedStatus) {
                    ForEach(self.status) { pickerStatus in
                        Text("\(pickerStatus.rawValue)")
                            .tag(pickerStatus)
                    }
                }
                // .pickerStyle(.palette)

                Spacer()
                Button {
                    Log.log("[UI] -> Show add new task", level: .info)
                    self.showAdding = true
                } label: {
                    Image(systemName: "plus")
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .frame(width: 30, height: 30)
                        .padding(5)
                        .background(Color.green.opacity(0.3))
                        .cornerRadius(20)
                }
            }

            if !self.viewModel.models.isEmpty {
                Toggle(isOn: self.$selectedAll) {
                    Text("Marked all as complete!")
                }
            }
        }
    }
}

// MARK: - Functions

extension ContentView {
    private func addTask() {
        Log.log("[UI] -> addTask", level: .info)
        self.viewModel.addNewTask(self.newTaskName)
        self.newTaskName = ""
    }

    private func update() {
        Log.log("[UI] -> update task", level: .info)
        guard let model = updatingModel else { return }
        self.viewModel.updateTask(model.id, self.newTaskName)

        self.newTaskName = ""
    }

    private func complete(_ taskID: String, complete: Bool) {
        Log.log("[UI] -> marks as compled task", level: .info)
        self.viewModel.updateTask(taskID, complete: complete)
    }

    private func removeAllCompleted() {
        Log.log("[UI] -> remove all completed task", level: .info)
        self.viewModel.removeAllCompleted()
    }
}

#Preview {
    ContentView()
}
