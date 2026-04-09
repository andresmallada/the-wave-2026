import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case geminiAPIKey
    case mcpServerURL
    case mcpAuthToken
    case geminiSystemPrompt
    case geminiVoice
    case geminiModel
    case thinkingBudget
    case responseLanguage
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case videoFrameRate
    case videoJPEGQuality
    case sendFramesToGemini
    case sendAudioToGemini
    case proactiveNotificationsEnabled
  }

  private init() {}

  // MARK: - Gemini

  var geminiAPIKey: String {
    get { defaults.string(forKey: Key.geminiAPIKey.rawValue) ?? Secrets.geminiAPIKey }
    set { defaults.set(newValue, forKey: Key.geminiAPIKey.rawValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? GeminiConfig.defaultSystemInstruction }
    set { defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue) }
  }

  var geminiVoice: String {
    get { defaults.string(forKey: Key.geminiVoice.rawValue) ?? "Puck" }
    set { defaults.set(newValue, forKey: Key.geminiVoice.rawValue) }
  }

  static let availableVoices = [
    "Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr",
    "Callirrhoe", "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba",
    "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
    "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi",
    "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
  ]

  var geminiModel: String {
    get { defaults.string(forKey: Key.geminiModel.rawValue) ?? GeminiConfig.defaultModel }
    set { defaults.set(newValue, forKey: Key.geminiModel.rawValue) }
  }

  static let availableModelIDs: [String] = [
    "models/gemini-2.5-flash-native-audio-preview-12-2025",
    "models/gemini-3.1-flash-live-preview"
  ]

  static func modelLabel(for id: String) -> String {
    switch id {
    case "models/gemini-2.5-flash-native-audio-preview-12-2025": return "2.5 Flash Live (12-2025)"
    case "models/gemini-3.1-flash-live-preview": return "3.1 Flash Live (NEW)"
    default: return id.replacingOccurrences(of: "models/", with: "")
    }
  }

  static let thinkingLevels = ["minimal", "low", "medium", "high"]

  var thinkingBudget: Int {
    get {
      let stored = defaults.object(forKey: Key.thinkingBudget.rawValue) as? Int
      return stored ?? 0
    }
    set { defaults.set(newValue, forKey: Key.thinkingBudget.rawValue) }
  }

  var thinkingLevel: String {
    get { defaults.string(forKey: "thinkingLevel") ?? "minimal" }
    set { defaults.set(newValue, forKey: "thinkingLevel") }
  }

  var isModel31: Bool {
    geminiModel.contains("3.1")
  }

  var responseLanguage: String {
    get { defaults.string(forKey: Key.responseLanguage.rawValue) ?? "Español" }
    set { defaults.set(newValue, forKey: Key.responseLanguage.rawValue) }
  }

  static let availableLanguages = ["Español", "English", "Français", "Deutsch", "Italiano", "Português"]

  // MARK: - MCP Server

  var mcpServerURL: String {
    get { defaults.string(forKey: Key.mcpServerURL.rawValue) ?? Secrets.mcpServerURL }
    set { defaults.set(newValue, forKey: Key.mcpServerURL.rawValue) }
  }

  var mcpAuthToken: String {
    get { defaults.string(forKey: Key.mcpAuthToken.rawValue) ?? Secrets.mcpAuthToken }
    set { defaults.set(newValue, forKey: Key.mcpAuthToken.rawValue) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { defaults.string(forKey: Key.webrtcSignalingURL.rawValue) ?? Secrets.webrtcSignalingURL }
    set { defaults.set(newValue, forKey: Key.webrtcSignalingURL.rawValue) }
  }

  // MARK: - Audio

  /// "glasses" | "speaker" | "usb"
  var audioOutputRoute: String {
    get {
      // Migrate legacy boolean value
      if let legacy = defaults.object(forKey: Key.speakerOutputEnabled.rawValue) as? Bool {
        defaults.set(legacy ? "speaker" : "glasses", forKey: Key.speakerOutputEnabled.rawValue)
        return legacy ? "speaker" : "glasses"
      }
      return defaults.string(forKey: Key.speakerOutputEnabled.rawValue) ?? "glasses"
    }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
  }

  static let audioOutputRouteIDs: [String] = ["glasses", "speaker", "usb"]

  static func audioOutputLabel(for id: String) -> String {
    switch id {
    case "glasses": return "Glasses (Bluetooth)"
    case "speaker": return "iPhone Speaker"
    case "usb": return "USB / HDMI"
    default: return id
    }
  }

  /// Legacy helper – true when audio goes through the phone speaker
  var speakerOutputEnabled: Bool {
    audioOutputRoute == "speaker"
  }

  // MARK: - Video

  var videoStreamingEnabled: Bool {
    get { defaults.object(forKey: Key.videoStreamingEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.videoStreamingEnabled.rawValue) }
  }

  var videoFrameRate: Double {
    get {
      let stored = defaults.double(forKey: Key.videoFrameRate.rawValue)
      return stored > 0 ? stored : 3.0
    }
    set { defaults.set(newValue, forKey: Key.videoFrameRate.rawValue) }
  }

  var videoJPEGQuality: Double {
    get {
      let stored = defaults.double(forKey: Key.videoJPEGQuality.rawValue)
      return stored > 0 ? stored : 0.5
    }
    set { defaults.set(newValue, forKey: Key.videoJPEGQuality.rawValue) }
  }

  var sendFramesToGemini: Bool {
    get { defaults.object(forKey: Key.sendFramesToGemini.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.sendFramesToGemini.rawValue) }
  }

  var sendAudioToGemini: Bool {
    get { defaults.object(forKey: Key.sendAudioToGemini.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.sendAudioToGemini.rawValue) }
  }

  // MARK: - Notifications

  var proactiveNotificationsEnabled: Bool {
    get { defaults.object(forKey: Key.proactiveNotificationsEnabled.rawValue) as? Bool ?? true }
    set { defaults.set(newValue, forKey: Key.proactiveNotificationsEnabled.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .geminiVoice, .geminiModel,
                .thinkingBudget, .responseLanguage, .mcpServerURL, .mcpAuthToken,
                .webrtcSignalingURL, .speakerOutputEnabled, .videoStreamingEnabled,
                .videoFrameRate, .videoJPEGQuality, .sendFramesToGemini, .sendAudioToGemini,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
