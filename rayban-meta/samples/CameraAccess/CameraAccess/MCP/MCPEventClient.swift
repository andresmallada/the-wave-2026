import Foundation

class MCPEventClient {
  var onNotification: ((String) -> Void)?
  var mcpSessionId: String?

  private var eventSource: URLSessionDataTask?
  private var session: URLSession?
  private var isConnected = false
  private var shouldReconnect = false
  private var reconnectDelay: TimeInterval = 2
  private let maxReconnectDelay: TimeInterval = 30
  private var buffer = ""

  func connect() {
    guard GeminiConfig.isMCPConfigured else {
      NSLog("[MCP-SSE] Not configured, skipping")
      return
    }

    shouldReconnect = true
    reconnectDelay = 2
    establishConnection()
  }

  func disconnect() {
    shouldReconnect = false
    isConnected = false
    eventSource?.cancel()
    eventSource = nil
    session?.invalidateAndCancel()
    session = nil
    buffer = ""
    NSLog("[MCP-SSE] Disconnected")
  }

  // MARK: - Private

  private func establishConnection() {
    let baseURL = GeminiConfig.mcpServerURL
    guard !baseURL.isEmpty, baseURL != "YOUR_MCP_SERVER_URL" else {
      NSLog("[MCP-SSE] Invalid URL")
      return
    }

    let endpoint = baseURL.hasSuffix("/mcp") ? baseURL : baseURL + "/mcp"
    guard let url = URL(string: endpoint) else {
      NSLog("[MCP-SSE] Invalid URL: %@", endpoint)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    if let sid = mcpSessionId {
      request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
    }

    let token = GeminiConfig.mcpAuthToken
    if !token.isEmpty && token != "YOUR_MCP_AUTH_TOKEN" {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = TimeInterval(Int32.max)
    config.timeoutIntervalForResource = TimeInterval(Int32.max)

    let delegate = SSEDelegate { [weak self] data in
      self?.handleSSEData(data)
    } onComplete: { [weak self] error in
      guard let self else { return }
      self.isConnected = false
      if let error {
        NSLog("[MCP-SSE] Connection error: %@", error.localizedDescription)
      }
      self.scheduleReconnect()
    }

    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    eventSource = session?.dataTask(with: request)
    eventSource?.resume()

    NSLog("[MCP-SSE] Connecting to %@", endpoint)
  }

  private func handleSSEData(_ data: Data) {
    guard let text = String(data: data, encoding: .utf8) else { return }
    buffer += text

    // Process complete SSE events (double newline separated)
    while let range = buffer.range(of: "\n\n") {
      let eventText = String(buffer[buffer.startIndex..<range.lowerBound])
      buffer = String(buffer[range.upperBound...])
      processSSEEvent(eventText)
    }
  }

  private func processSSEEvent(_ eventText: String) {
    var eventType = "message"
    var eventData = ""

    for line in eventText.components(separatedBy: "\n") {
      if line.hasPrefix("event:") {
        eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("data:") {
        let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if !eventData.isEmpty { eventData += "\n" }
        eventData += dataLine
      }
    }

    guard !eventData.isEmpty else { return }

    if !isConnected {
      isConnected = true
      reconnectDelay = 2
      NSLog("[MCP-SSE] Connected, receiving events")
    }

    // Parse JSON-RPC notification
    guard let data = eventData.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = json["method"] as? String else {
      return
    }

    let params = json["params"] as? [String: Any] ?? [:]

    switch method {
    case "notifications/message":
      handleMessageNotification(params)
    case "notifications/tools/list_changed":
      NSLog("[MCP-SSE] Tools list changed, will refresh on next session")
    default:
      NSLog("[MCP-SSE] Unhandled notification: %@", method)
    }
  }

  private func handleMessageNotification(_ params: [String: Any]) {
    guard let content = params["content"] as? String, !content.isEmpty else { return }
    let level = params["level"] as? String ?? "info"
    guard level != "debug" else { return }

    NSLog("[MCP-SSE] Notification (%@): %@", level, String(content.prefix(100)))
    onNotification?("[Notification] \(content)")
  }

  private func scheduleReconnect() {
    guard shouldReconnect else { return }
    NSLog("[MCP-SSE] Reconnecting in %.0fs", reconnectDelay)
    DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
      guard let self, self.shouldReconnect else { return }
      self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
      self.establishConnection()
    }
  }
}

// MARK: - SSE URLSession Delegate

private class SSEDelegate: NSObject, URLSessionDataDelegate {
  let onData: (Data) -> Void
  let onComplete: (Error?) -> Void

  init(onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
    self.onData = onData
    self.onComplete = onComplete
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    onData(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    onComplete(error)
  }
}
