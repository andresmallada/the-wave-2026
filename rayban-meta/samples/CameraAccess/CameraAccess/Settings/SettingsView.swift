import SwiftUI

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var geminiAPIKey: String = ""
  @State private var mcpServerURL: String = ""
  @State private var mcpAuthToken: String = ""
  @State private var geminiSystemPrompt: String = ""
  @State private var geminiVoice: String = "Puck"
  @State private var geminiModel: String = GeminiConfig.defaultModel
  @State private var thinkingBudget: Double = 0
  @State private var thinkingLevel: String = "minimal"
  @State private var responseLanguage: String = "Español"
  @State private var webrtcSignalingURL: String = ""
  @State private var audioOutputRoute: String = "glasses"
  @State private var videoStreamingEnabled: Bool = true
  @State private var videoFrameRate: Double = 3.0
  @State private var videoJPEGQuality: Double = 0.5
  @State private var proactiveNotificationsEnabled: Bool = true
  @State private var showResetConfirmation = false
  @State private var hasLoaded = false

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Gemini API")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Enter Gemini API key", text: $geminiAPIKey)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("AI Agent"), footer: Text("Changes take effect on the next Gemini session.")) {
          Picker("Model", selection: $geminiModel) {
            ForEach(SettingsManager.availableModelIDs, id: \.self) { modelId in
              Text(SettingsManager.modelLabel(for: modelId)).tag(modelId)
            }
          }

          Picker("Voice", selection: $geminiVoice) {
            ForEach(SettingsManager.availableVoices, id: \.self) { voice in
              Text(voice).tag(voice)
            }
          }
          .pickerStyle(.navigationLink)

          Picker("Language", selection: $responseLanguage) {
            ForEach(SettingsManager.availableLanguages, id: \.self) { lang in
              Text(lang).tag(lang)
            }
          }

          if geminiModel.contains("3.1") {
            Picker("Thinking", selection: $thinkingLevel) {
              ForEach(SettingsManager.thinkingLevels, id: \.self) { level in
                Text(level.capitalized).tag(level)
              }
            }
          } else {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text("Thinking Budget")
                  .font(.caption)
                  .foregroundColor(.secondary)
                Spacer()
                Text(thinkingBudget == 0 ? "Off" : "\(Int(thinkingBudget))")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Slider(value: $thinkingBudget, in: 0...8192, step: 1024)
            }
          }
        }

        Section(header: Text("System Prompt"), footer: Text("Customize the AI assistant's behavior and personality. Changes take effect on the next Gemini session.")) {
          TextEditor(text: $geminiSystemPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 200)
        }

        Section(header: Text("MCP Server"), footer: Text("Connect to your custom MCP server for agentic tool-calling. The server should be accessible via Cloudflare Tunnel or similar.")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Server URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("https://your-server.trycloudflare.com", text: $mcpServerURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: 4) {
            Text("Auth Token")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("Bearer token (optional)", text: $mcpAuthToken)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("WebRTC")) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Signaling URL")
              .font(.caption)
              .foregroundColor(.secondary)
            TextField("wss://your-server.example.com", text: $webrtcSignalingURL)
              .autocapitalization(.none)
              .disableAutocorrection(true)
              .keyboardType(.URL)
              .font(.system(.body, design: .monospaced))
          }
        }

        Section(header: Text("Audio Output"), footer: Text("Glasses: audio through Ray-Ban speakers via Bluetooth.\nSpeaker: iPhone built-in speaker.\nUSB/HDMI: routes audio through USB-C for capture with OBS.")) {
          Picker("Output", selection: $audioOutputRoute) {
            ForEach(SettingsManager.audioOutputRouteIDs, id: \.self) { routeId in
              Text(SettingsManager.audioOutputLabel(for: routeId)).tag(routeId)
            }
          }
          .pickerStyle(.segmented)
        }

        Section(header: Text("Video"), footer: Text("Video Streaming captures frames from the camera. Use the Mic/Video toggles on the streaming screen to control what is sent to Gemini.")) {
          Toggle("Video Streaming", isOn: $videoStreamingEnabled)

          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Frame Rate")
                .font(.caption)
                .foregroundColor(.secondary)
              Spacer()
              Text("\(Int(videoFrameRate)) fps")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Slider(value: $videoFrameRate, in: 1...10, step: 1)
          }

          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("JPEG Quality")
                .font(.caption)
                .foregroundColor(.secondary)
              Spacer()
              Text("\(Int(videoJPEGQuality * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Slider(value: $videoJPEGQuality, in: 0.1...1.0, step: 0.1)
          }
        }

        Section(header: Text("Notifications"), footer: Text("Receive proactive updates from your MCP server spoken through the glasses.")) {
          Toggle("Proactive Notifications", isOn: $proactiveNotificationsEnabled)
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            save()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        guard !hasLoaded else { return }
        hasLoaded = true
        loadCurrentValues()
      }
    }
  }

  private func loadCurrentValues() {
    geminiAPIKey = settings.geminiAPIKey
    geminiSystemPrompt = settings.geminiSystemPrompt
    geminiVoice = settings.geminiVoice
    geminiModel = settings.geminiModel
    thinkingBudget = Double(settings.thinkingBudget)
    thinkingLevel = settings.thinkingLevel
    responseLanguage = settings.responseLanguage
    mcpServerURL = settings.mcpServerURL
    mcpAuthToken = settings.mcpAuthToken
    webrtcSignalingURL = settings.webrtcSignalingURL
    audioOutputRoute = settings.audioOutputRoute
    videoStreamingEnabled = settings.videoStreamingEnabled
    videoFrameRate = settings.videoFrameRate
    videoJPEGQuality = settings.videoJPEGQuality
    proactiveNotificationsEnabled = settings.proactiveNotificationsEnabled
  }

  private func save() {
    settings.geminiAPIKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiSystemPrompt = geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.geminiVoice = geminiVoice
    settings.geminiModel = geminiModel
    settings.thinkingBudget = Int(thinkingBudget)
    settings.thinkingLevel = thinkingLevel
    settings.responseLanguage = responseLanguage
    settings.mcpServerURL = mcpServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.mcpAuthToken = mcpAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.webrtcSignalingURL = webrtcSignalingURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.audioOutputRoute = audioOutputRoute
    settings.videoStreamingEnabled = videoStreamingEnabled
    settings.videoFrameRate = videoFrameRate
    settings.videoJPEGQuality = videoJPEGQuality
    settings.proactiveNotificationsEnabled = proactiveNotificationsEnabled
  }
}
