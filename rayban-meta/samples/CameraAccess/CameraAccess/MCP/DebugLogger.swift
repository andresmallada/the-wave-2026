import Foundation
import SwiftUI

/// Thread-safe singleton in-app logger. Call from any thread.
/// Usage: AppLog("Tag", "message")
final class DebugLogger: ObservableObject {
  static let shared = DebugLogger()

  struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let tag: String
    let message: String

    var formatted: String {
      let tf = DateFormatter()
      tf.dateFormat = "HH:mm:ss.SSS"
      return "[\(tf.string(from: timestamp))] [\(tag)] \(message)"
    }
  }

  @Published var entries: [LogEntry] = []
  private let maxEntries = 500
  private let queue = DispatchQueue(label: "debug-logger", qos: .utility)

  private init() {}

  /// Thread-safe log method - can be called from any queue
  func log(_ tag: String, _ message: String) {
    let entry = LogEntry(timestamp: Date(), tag: tag, message: message)
    NSLog("[%@] %@", tag, message)
    queue.async {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.entries.append(entry)
        if self.entries.count > self.maxEntries {
          self.entries.removeFirst(self.entries.count - self.maxEntries)
        }
      }
    }
  }

  func clear() {
    DispatchQueue.main.async { [weak self] in
      self?.entries.removeAll()
    }
  }

  var allText: String {
    entries.map { $0.formatted }.joined(separator: "\n")
  }

  /// Log current app configuration at startup
  func logStartupDiagnostics() {
    log("App", "=== TheWave Agent startup ===")
    log("App", "Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
    log("App", "Gemini key: \(GeminiConfig.apiKey.prefix(10))...")
    log("App", "MCP URL: \(GeminiConfig.mcpServerURL)")
    log("App", "MCP token: \(GeminiConfig.mcpAuthToken.prefix(10))...")
    log("App", "MCP configured: \(GeminiConfig.isMCPConfigured)")
    log("App", "WebRTC URL: \(SettingsManager.shared.webrtcSignalingURL)")
  }
}

/// Convenience global function
func AppLog(_ tag: String, _ message: String) {
  DebugLogger.shared.log(tag, message)
}

// MARK: - Debug Console View

struct DebugConsoleView: View {
  @ObservedObject private var logger = DebugLogger.shared
  @Environment(\.dismiss) private var dismiss
  @State private var autoScroll = true
  @State private var showCopied = false

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Status bar
        HStack {
          Circle()
            .fill(logger.entries.isEmpty ? .gray : .green)
            .frame(width: 8, height: 8)
          Text("\(logger.entries.count) logs")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Toggle("Auto-scroll", isOn: $autoScroll)
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGroupedBackground))

        // Log entries
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(logger.entries) { entry in
                Text(entry.formatted)
                  .font(.system(size: 11, design: .monospaced))
                  .foregroundColor(colorFor(entry.tag))
                  .id(entry.id)
                  .textSelection(.enabled)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
          }
          .background(Color.black)
          .onChange(of: logger.entries.count) { _ in
            if autoScroll, let last = logger.entries.last {
              withAnimation {
                proxy.scrollTo(last.id, anchor: .bottom)
              }
            }
          }
        }
      }
      .navigationTitle("Debug Console")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") { dismiss() }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          Button {
            UIPasteboard.general.string = logger.allText
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
              showCopied = false
            }
          } label: {
            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
          }
          Button {
            logger.clear()
          } label: {
            Image(systemName: "trash")
              .foregroundColor(.red)
          }
        }
      }
    }
  }

  private func colorFor(_ tag: String) -> Color {
    switch tag {
    case "ERROR": return .red
    case "Gemini": return .cyan
    case "MCP": return .yellow
    case "ToolCall": return .orange
    case "Session": return .green
    case "WebRTC": return .purple
    case "Audio": return .mint
    default: return .white
    }
  }
}
