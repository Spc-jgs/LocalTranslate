import SwiftUI

struct SettingsView: View {

    @AppStorage(AppSettings.Key.model)
    private var model = AppSettings.defaultModel

    @AppStorage(AppSettings.Key.baseURL)
    private var baseURL = AppSettings.defaultBaseURL

    @AppStorage(AppSettings.Key.keepAlive)
    private var keepAlive = AppSettings.defaultKeepAlive

    @State private var installedModels: [String] = []

    @State private var isLoadingModels = false

    @State private var modelLoadError: String?

    private var pickerModels: [String] {

        var models = installedModels

        // 如果当前配置里的模型已经被删了，
        // 仍然先把它显示出来，避免 Picker selection 无对应项。
        if !model.isEmpty &&
            !models.contains(model) {

            models.insert(
                model,
                at: 0
            )
        }

        return models
    }

    private var selectedModelInstalled: Bool {

        installedModels.contains(
            model
        )
    }

    var body: some View {

        Form {

            // MARK: - Ollama

            Section("Ollama") {

                LabeledContent("地址") {

                    TextField(
                        "",
                        text: $baseURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        Task {
                            await loadModels()
                        }
                    }
                }

                LabeledContent("模型") {

                    HStack(spacing: 8) {

                        Picker(
                            "",
                            selection: $model
                        ) {

                            if pickerModels.isEmpty {

                                Text("没有可用模型")
                                    .tag("")

                            } else {

                                ForEach(
                                    pickerModels,
                                    id: \.self
                                ) { modelName in

                                    Text(modelName)
                                        .tag(modelName)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)

                        Button {
                            Task {
                                await loadModels()
                            }
                        } label: {

                            if isLoadingModels {

                                ProgressView()
                                    .controlSize(.small)

                            } else {

                                Image(
                                    systemName: "arrow.clockwise"
                                )
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingModels)
                        .help("刷新模型列表")
                    }
                }

                Picker(
                    "模型驻留时间",
                    selection: $keepAlive
                ) {

                    Text("立即释放")
                        .tag("0")

                    Text("5 分钟")
                        .tag("5m")

                    Text("10 分钟")
                        .tag("10m")

                    Text("30 分钟")
                        .tag("30m")

                    Text("1 小时")
                        .tag("1h")
                }

                // MARK: Status

                LabeledContent("状态") {

                    if isLoadingModels {

                        HStack(spacing: 6) {

                            ProgressView()
                                .controlSize(.small)

                            Text("正在连接…")
                                .foregroundStyle(.secondary)
                        }

                    } else if let modelLoadError {

                        HStack(spacing: 6) {

                            Image(
                                systemName: "exclamationmark.circle.fill"
                            )
                            .foregroundStyle(.red)

                            Text(modelLoadError)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                    } else {

                        HStack(spacing: 6) {

                            Circle()
                                .fill(.green)
                                .frame(
                                    width: 7,
                                    height: 7
                                )

                            Text(
                                "已连接 · \(installedModels.count) 个模型"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if !installedModels.isEmpty &&
                    !model.isEmpty &&
                    !selectedModelInstalled {

                    Label(
                        "当前选择的模型未安装，请重新选择。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            // MARK: - HotKey

            Section("快捷键") {

                LabeledContent("翻译") {

                    Text("⌥ ⇧ T")
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Reset

            Section {

                Button("恢复默认设置") {

                    model =
                        AppSettings.defaultModel

                    baseURL =
                        AppSettings.defaultBaseURL

                    keepAlive =
                        AppSettings.defaultKeepAlive

                    Task {
                        await loadModels()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(
            width: 500,
            height: 380
        )
        .padding()
        .task {
            await loadModels()
        }
    }

    @MainActor
    private func loadModels() async {

        guard !isLoadingModels else {
            return
        }

        isLoadingModels = true
        modelLoadError = nil

        do {

            let models = try await
                OllamaClient.shared
                    .installedModelNames()

            installedModels = models

            // 首次使用且没有模型配置时，
            // 默认选择列表中的第一个。
            if model.isEmpty,
               let firstModel = models.first {

                model = firstModel
            }

        } catch {

            installedModels = []

            modelLoadError =
                error.localizedDescription
        }

        isLoadingModels = false
    }
}

#Preview {
    SettingsView()
}
