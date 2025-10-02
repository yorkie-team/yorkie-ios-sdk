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
import Combine

struct ContentView: View {
    enum Status: String, Identifiable {
        var id: String { rawValue }
        
        case all = "All"
        case active = "Active"
        case completed = "Completed"
    }
    @State private var viewModel = ContentViewModel()
    @State private var selectedStatus = Status.all
    @State private var showAdding = false
    @State private var showEdditing = false
    @State private var selectedAll = false
    @State private var newTaskName = ""
    @State private var updatingModel: TodoModel? = nil
    
    private let status: [Status] = [.all, .active, .completed]
    var body: some View {
        Group {
            let _ = Self._printChanges()
            switch viewModel.state {
            case .error(let error):
                errorView(error)
            case .loading:
                loadingView
            case .success:
                content
            }
        }
        .task {
            await viewModel.initializeClient()
        }
    }
}

// MARK: - Views
extension ContentView {
    private var content: some View {
        NavigationStack {
            VStack {
                headerView
                
                Spacer()
                
                ScrollView {
                    let filteredModels: [TodoModel] = {
                        switch selectedStatus {
                        case .all:
                            return viewModel.models
                        case .active:
                            return viewModel.models.filter { !$0.completed }
                        case .completed:
                            return viewModel.models.filter { $0.completed }
                        }
                    }()
                    ForEach(filteredModels) { model in
                        HStack(spacing: 20) {
                            Button {
                                complete(model.id, complete: !model.completed)
                            } label: {
                                Image(systemName: model.completed ? "checkmark.circle" : "circle")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 25, height: 25, alignment: .center)
                            }
                            
                            Button {
                                updatingModel = model
                                showEdditing = true
                                newTaskName = model.text
                            } label: {
                                Text("\(model.text)")
                                    .strikethrough(model.completed)
                            }
                            
                            Spacer()
                            Button {
                                viewModel.deleteItem(model.id)
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
                    if viewModel.itemsLeft > 0 {
                        Text("\(viewModel.itemsLeft) item(s) left")
                    } else {
                        
                        Text("No items left")
                    }
                    
                    if viewModel.models.contains(where: { $0.completed }) {
                        Button {
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
            .alert("Add New Todo", isPresented: $showAdding) {
                TextField("What needs to be done?", text: $newTaskName)
                HStack {
                    Button(role: .confirm, action: addTask)
                    Button(role: .cancel) {
                        showAdding = false
                    }
                }
            } message: {
                Text("Add new task to do here!")
            }
            .alert("Edit task name", isPresented: $showEdditing) {
                TextField("What needs to be done?", text: $newTaskName)
                HStack {
                    Button(role: .close, action: update)
                    // Button(role: .confirm, action: update)
                    Button(role: .cancel) {
                        showEdditing = false
                    }
                }
            } message: {
                Text("Add new task to do here!")
            }
            .navigationTitle("Todo")
            .onChange(of: viewModel.models) { _, newValue in
                let hasChanged = newValue.contains(where: { $0.completed == false })
                selectedAll = !hasChanged
            }
            .onChange(of: selectedAll) { oldValue, newValue in
                viewModel.markAllAsComplete(newValue)
            }
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
                Picker("", selection: $selectedStatus) {
                    ForEach(status) { pickerStatus in
                        Text("\(pickerStatus.rawValue)")
                            .tag(pickerStatus)
                    }
                }
                .pickerStyle(.palette)
                
                Spacer()
                Button {
                    showAdding = true
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
            
            if !viewModel.models.isEmpty {
                Toggle(isOn: $selectedAll) {
                    Text("Marked all as complete!")
                }
            }
        }
    }
}

// MARK: - Functions
extension ContentView {
    private func addTask() {
        viewModel.addNewTask(newTaskName)
        newTaskName = ""
    }
    
    private func update() {
        guard let model = updatingModel else { return }
        viewModel.updateTask(model.id, newTaskName)
    }
    
    private func complete(_ taskID: String, complete: Bool) {
        viewModel.updateTask(taskID, complete: complete)
    }
    
    private func removeAllCompleted() {
        viewModel.removeAllCompleted()
    }
}

#Preview {
    ContentView()
}
