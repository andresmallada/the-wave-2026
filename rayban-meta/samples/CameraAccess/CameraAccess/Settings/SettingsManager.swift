import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case geminiAPIKey
    case mcpServerURL
    case mcpAuthToken
    case geminiSystemPrompt
    case webrtcSignalingURL
    case speakerOutputEnabled
    case videoStreamingEnabled
    case videoFrameRate
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

  var speakerOutputEnabled: Bool {
    get { defaults.bool(forKey: Key.speakerOutputEnabled.rawValue) }
    set { defaults.set(newValue, forKey: Key.speakerOutputEnabled.rawValue) }
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
    for key in [Key.geminiAPIKey, .geminiSystemPrompt, .mcpServerURL, .mcpAuthToken,
                .webrtcSignalingURL, .speakerOutputEnabled, .videoStreamingEnabled,
                .videoFrameRate, .sendFramesToGemini, .sendAudioToGemini,
                .proactiveNotificationsEnabled] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}
