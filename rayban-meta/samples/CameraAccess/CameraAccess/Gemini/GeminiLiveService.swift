import Foundation
import UIKit

enum GeminiConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

@MainActor
class GeminiLiveService: ObservableObject {
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onAudioReceived: ((Data) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?
  var onInputTranscription: ((String) -> Void)?
  var onOutputTranscription: ((String) -> Void)?
  var onToolCall: ((GeminiToolCall) -> Void)?
  var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?

  // Latency tracking
  private var lastUserSpeechEnd: Date?
  private var responseLatencyLogged = false

  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var connectContinuation: CheckedContinuation<Bool, Never>?
  private let delegate = WebSocketDelegate()
  private var urlSession: URLSession?
  private let sendQueue = DispatchQueue(label: "gemini.send", qos: .userInitiated)
  private let maxRetries = 2

  /// Tool declarations to register with Gemini. Set before calling connect().
  var toolDeclarations: [[String: Any]] = []

  func connect() async -> Bool {
    guard let url = GeminiConfig.websocketURL() else {
      connectionState = .error("No API key configured")
      return false
    }

    AppLog("Gemini", "Connecting to: \(url.absoluteString.prefix(80))...")

    for attempt in 0...maxRetries {
      if attempt > 0 {
        AppLog("Gemini", "Retry \(attempt)/\(maxRetries) after 1s delay...")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }

      let success = await attemptConnect(url: url)
      if success { return true }
    }

    AppLog("ERROR", "All \(maxRetries + 1) connection attempts failed")
    return false
  }

  private func attemptConnect(url: URL) async -> Bool {
    // Clean up any previous attempt — nil callbacks first to prevent stale fires
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    urlSession?.invalidateAndCancel()
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    self.urlSession = session

    connectionState = .connecting

    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.connectContinuation = continuation

      self.delegate.onOpen = { [weak self] protocol_ in
        guard let self else { return }
        AppLog("Gemini", "WebSocket opened (protocol: \(protocol_ ?? "none"))")
        Task { @MainActor in
          self.connectionState = .settingUp
          self.sendSetupMessage()
          self.startReceiving()
        }
      }

      self.delegate.onClose = { [weak self] code, reason in
        guard let self else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        AppLog("Gemini", "WebSocket closed: code=\(code.rawValue), reason=\(reasonStr)")
        Task { @MainActor in
          let wasReady = self.connectionState == .ready
          self.resolveConnect(success: false)
          self.connectionState = .disconnected
          self.isModelSpeaking = false
          if wasReady {
            self.onDisconnected?("Connection closed (code \(code.rawValue): \(reasonStr))")
          }
        }
      }

      self.delegate.onError = { [weak self] error in
        guard let self else { return }
        let msg = error?.localizedDescription ?? "Unknown error"
        AppLog("ERROR", "WebSocket error: \(msg)")
        Task { @MainActor in
          let wasReady = self.connectionState == .ready
          self.resolveConnect(success: false)
          self.connectionState = .error(msg)
          self.isModelSpeaking = false
          if wasReady {
            self.onDisconnected?(msg)
          }
        }
      }

      self.webSocketTask = session.webSocketTask(with: url)
      self.webSocketTask?.resume()

      // Timeout after 15 seconds
      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          self.resolveConnect(success: false)
          if self.connectionState == .connecting || self.connectionState == .settingUp {
            self.connectionState = .error("Connection timed out")
          }
        }
      }
    }

    return result
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    onToolCall = nil
    onToolCallCancellation = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
    connectionState = .disconnected
    isModelSpeaking = false
    resolveConnect(success: false)
  }

  func sendAudio(data: Data) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      let base64 = data.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "audio": [
            "mimeType": "audio/pcm;rate=16000",
            "data": base64
          ]
        ]
      ]
      self?.sendJSON(json)
    }
  }

  private var videoFrameLogCount = 0

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      guard let self else { return }
      let quality = GeminiConfig.videoJPEGQuality
      guard let jpegData = image.jpegData(compressionQuality: quality) else { return }
      self.videoFrameLogCount += 1
      if self.videoFrameLogCount <= 3 || self.videoFrameLogCount % 100 == 0 {
        AppLog("Gemini", "Video frame #\(self.videoFrameLogCount): \(Int(image.size.width))x\(Int(image.size.height)) JPEG q=\(Int(quality * 100))% size=\(jpegData.count / 1024)KB")
      }
      let base64 = jpegData.base64EncodedString()
      let json: [String: Any] = [
        "realtimeInput": [
          "video": [
            "mimeType": "image/jpeg",
            "data": base64
          ]
        ]
      ]
      self.sendJSON(json)
    }
  }

  func sendToolResponse(_ response: [String: Any]) {
    AppLog("Gemini", "Sending toolResponse back to model")
    sendQueue.async { [weak self] in
      self?.sendJSON(response)
      AppLog("Gemini", "toolResponse sent successfully")
    }
  }

  func sendTextMessage(_ text: String) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      let msg: [String: Any] = [
        "clientContent": [
          "turns": [
            ["role": "user", "parts": [["text": text]]]
          ]
        ]
      ]
      self?.sendJSON(msg)
    }
  }

  // MARK: - Private

  private func resolveConnect(success: Bool) {
    if let cont = connectContinuation {
      connectContinuation = nil
      cont.resume(returning: success)
    }
  }

  private func sendSetupMessage() {
    let voice = GeminiConfig.voice
    let model = GeminiConfig.model
    let is31 = GeminiConfig.isModel31
    let lang = GeminiConfig.responseLanguage

    // Thinking config differs by model generation
    let thinkingConfig: [String: Any]
    if is31 {
      let level = GeminiConfig.thinkingLevel
      thinkingConfig = ["thinkingLevel": level]
      AppLog("Gemini", "Setup: model=\(model), voice=\(voice), thinkingLevel=\(level), lang=\(lang)")
    } else {
      let budget = GeminiConfig.thinkingBudget
      thinkingConfig = ["thinkingBudget": budget]
      AppLog("Gemini", "Setup: model=\(model), voice=\(voice), thinkingBudget=\(budget), lang=\(lang)")
    }

    AppLog("Gemini", "Sending setup with \(toolDeclarations.count) tool declaration(s)")
    for decl in toolDeclarations {
      AppLog("Gemini", "  Tool: \(decl["name"] as? String ?? "unknown")")
    }

    let systemText = GeminiConfig.systemInstruction + "\n\nIMPORTANT: Always respond in \(lang)."

    let setup: [String: Any] = [
      "setup": [
        "model": model,
        "generationConfig": [
          "responseModalities": ["AUDIO"],
          "speechConfig": [
            "voiceConfig": [
              "prebuiltVoiceConfig": [
                "voiceName": voice
              ]
            ]
          ],
          "thinkingConfig": thinkingConfig
        ],
        "systemInstruction": [
          "parts": [
            ["text": systemText]
          ]
        ],
        "tools": toolDeclarations.isEmpty ? [] as [[String: Any]] : [
          [
            "functionDeclarations": toolDeclarations
          ]
        ],
        "realtimeInputConfig": [
          "automaticActivityDetection": [
            "disabled": false,
            "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
            "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
            "silenceDurationMs": 500,
            "prefixPaddingMs": 40
          ],
          "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
          "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
        ],
        "contextWindowCompression": [
          "slidingWindow": [
            "targetTokens": 80000
          ]
        ],
        "inputAudioTranscription": [:] as [String: Any],
        "outputAudioTranscription": [:] as [String: Any]
      ]
    ]
    sendJSON(setup)
  }

  private func sendJSON(_ json: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let string = String(data: data, encoding: .utf8) else {
      return
    }
    webSocketTask?.send(.string(string)) { error in
      if let error {
        AppLog("ERROR", "WebSocket send failed: \(error.localizedDescription)")
      }
    }
  }

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        guard let task = self.webSocketTask else { break }
        do {
          let message = try await task.receive()
          switch message {
          case .string(let text):
            await self.handleMessage(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              await self.handleMessage(text)
            }
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            let reason = error.localizedDescription
            AppLog("ERROR", "WebSocket receive failed: \(reason)")
            await MainActor.run {
              let wasReady = self.connectionState == .ready
              self.resolveConnect(success: false)
              self.connectionState = .disconnected
              self.isModelSpeaking = false
              if wasReady {
                self.onDisconnected?(reason)
              }
            }
          }
          break
        }
      }
    }
  }

  private func handleMessage(_ text: String) async {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return
    }

    // Setup complete
    if json["setupComplete"] != nil {
      AppLog("Gemini", "setupComplete received — connection ready")
      connectionState = .ready
      resolveConnect(success: true)
      return
    }

    // GoAway - server will close soon
    if let goAway = json["goAway"] as? [String: Any] {
      let timeLeft = goAway["timeLeft"] as? [String: Any]
      let seconds = timeLeft?["seconds"] as? Int ?? 0
      connectionState = .disconnected
      isModelSpeaking = false
      onDisconnected?("Server closing (time left: \(seconds)s)")
      return
    }

    // Tool call from model (top-level message, not inside serverContent)
    if let toolCall = GeminiToolCall(json: json) {
      AppLog("Gemini", "Tool call received: \(toolCall.functionCalls.count) function(s)")
      onToolCall?(toolCall)
      return
    }

    // Tool call cancellation (user interrupted during tool execution)
    if let cancellation = GeminiToolCallCancellation(json: json) {
      AppLog("Gemini", "Tool call cancellation: \(cancellation.ids.joined(separator: ", "))")
      onToolCallCancellation?(cancellation)
      return
    }

    // Server content
    if let serverContent = json["serverContent"] as? [String: Any] {
      if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
        isModelSpeaking = false
        onInterrupted?()
        return
      }

      if let modelTurn = serverContent["modelTurn"] as? [String: Any],
         let parts = modelTurn["parts"] as? [[String: Any]] {
        for part in parts {
          if let inlineData = part["inlineData"] as? [String: Any],
             let mimeType = inlineData["mimeType"] as? String,
             mimeType.hasPrefix("audio/pcm"),
             let base64Data = inlineData["data"] as? String,
             let audioData = Data(base64Encoded: base64Data) {
            if !isModelSpeaking {
              isModelSpeaking = true
              // Log latency: time from end of user speech to first audio response
              if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
                let latency = Date().timeIntervalSince(speechEnd)
                NSLog("[Latency] %.0fms (user speech end -> first audio)", latency * 1000)
                responseLatencyLogged = true
              }
            }
            onAudioReceived?(audioData)
          } else if let text = part["text"] as? String {
            NSLog("[Gemini] %@", text)
          }
        }
      }

      if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
        isModelSpeaking = false
        responseLatencyLogged = false
        onTurnComplete?()
      }

      if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
         let text = inputTranscription["text"] as? String, !text.isEmpty {
        NSLog("[Gemini] You: %@", text)
        lastUserSpeechEnd = Date()
        responseLatencyLogged = false
        onInputTranscription?(text)
      }
      if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
         let text = outputTranscription["text"] as? String, !text.isEmpty {
        NSLog("[Gemini] AI: %@", text)
        onOutputTranscription?(text)
      }
    }
  }
}

// MARK: - WebSocket Delegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
  var onOpen: ((String?) -> Void)?
  var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
  var onError: ((Error?) -> Void)?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    onOpen?(`protocol`)
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    onClose?(closeCode, reason)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      onError?(error)
    }
  }
}
