/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .high
  @Published var selectedFrameRate: Int = 24
  @Published var useHEVCCodec: Bool = true

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // WebRTC Live streaming integration
  var webrtcSessionVM: WebRTCSessionViewModel?

  // The core DAT SDK StreamSession - handles all streaming operations
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?

  // GPU-accelerated CIContext for foreground HEVC frame rendering (fast, high quality)
  private let gpuCIContext = CIContext(options: [.useSoftwareRenderer: false])
  // CPU-based CIContext for background rendering (GPU suspended by iOS in background)
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false
  private var fgFrameCount = 0

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    let savedRes = Self.resolutionFromString(SettingsManager.shared.streamingResolution)
    let savedFps = SettingsManager.shared.streamingFrameRate
    let savedHEVC = SettingsManager.shared.useHEVCCodec
    self.selectedResolution = savedRes
    self.selectedFrameRate = savedFps
    self.useHEVCCodec = savedHEVC
    let codec: VideoCodec = savedHEVC ? .hvc1 : .raw
    let config = StreamSessionConfig(
      videoCodec: codec,
      resolution: savedRes,
      frameRate: UInt(savedFps))
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }

    setupVideoDecoder()
    attachListeners()
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let isInBg = UIApplication.shared.applicationState == .background
        let ctx = isInBg ? self.cpuCIContext : self.gpuCIContext
        if let cgImage = ctx.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          if !isInBg {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame { self.hasReceivedFirstFrame = true }
            self.fgFrameCount += 1
            if self.fgFrameCount <= 5 || self.fgFrameCount % 200 == 0 {
              AppLog("Stream", "HEVC frame #\(self.fgFrameCount): \(width)x\(height) (requested: \(self.resolutionLabel), \(self.selectedFrameRate)fps)")
            }
          } else if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            AppLog("Stream", "BG frame #\(self.backgroundFrameCount) decoded (\(width)x\(height))")
          }
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          self.webrtcSessionVM?.pushVideoFrame(image)
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    SettingsManager.shared.streamingResolution = Self.resolutionToString(resolution)
    rebuildStreamSession()
    AppLog("Stream", "Resolution changed to \(resolutionLabel)")
  }

  func updateFrameRate(_ fps: Int) {
    guard !isStreaming else { return }
    selectedFrameRate = fps
    SettingsManager.shared.streamingFrameRate = fps
    rebuildStreamSession()
    AppLog("Stream", "Frame rate changed to \(fps) fps")
  }

  func updateCodec(_ hevc: Bool) {
    guard !isStreaming else { return }
    useHEVCCodec = hevc
    SettingsManager.shared.useHEVCCodec = hevc
    rebuildStreamSession()
    AppLog("Stream", "Codec changed to \(hevc ? "HEVC (hvc1)" : "Raw")")
  }

  private var selectedCodec: VideoCodec {
    useHEVCCodec ? .hvc1 : .raw
  }

  private func rebuildStreamSession() {
    let config = StreamSessionConfig(
      videoCodec: selectedCodec,
      resolution: selectedResolution,
      frameRate: UInt(selectedFrameRate))
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    attachListeners()
  }

  private static func resolutionFromString(_ str: String) -> StreamingResolution {
    switch str {
    case "low": return .low
    case "medium": return .medium
    default: return .high
    }
  }

  private static func resolutionToString(_ res: StreamingResolution) -> String {
    switch res {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    @unknown default: return "high"
    }
  }

  private func attachListeners() {
    // Subscribe to session state changes using the DAT SDK listener pattern
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            // Raw codec: makeUIImage() works directly
            self.fgFrameCount += 1
            if self.fgFrameCount <= 5 || self.fgFrameCount % 200 == 0 {
              AppLog("Stream", "Raw frame #\(self.fgFrameCount): \(Int(image.size.width))x\(Int(image.size.height)) (requested: \(self.resolutionLabel), \(self.selectedFrameRate)fps)")
            }
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            self.webrtcSessionVM?.pushVideoFrame(image)
          } else {
            // HEVC codec: makeUIImage() returns nil, decode via VideoDecoder
            let sampleBuffer = videoFrame.sampleBuffer
            let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil
            if hasCompressedData {
              do {
                try self.videoDecoder.decode(sampleBuffer)
              } catch {
                self.fgFrameCount += 1
                if self.fgFrameCount <= 5 {
                  AppLog("ERROR", "HEVC FG decode error: \(error)")
                }
              }
            }
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                AppLog("ERROR", "BG frame #\(self.backgroundFrameCount) decode error: \(error)")
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
              self.webrtcSessionVM?.pushVideoFrame(image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Suppress device-not-found errors when user hasn't started streaming yet
        if self.streamingStatus == .stopped {
          if case .deviceNotConnected = error { return }
          if case .deviceNotFound = error { return }
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    updateStatusFromState(streamSession.state)

    // Subscribe to photo capture events
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    await streamSession.start()
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    await streamSession.stop()
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        self.webrtcSessionVM?.pushVideoFrame(image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    AppLog("Stream", "iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    AppLog("Stream", "iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    streamSession.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .thermalCritical:
      return "Device overheating. Streaming paused to cool down."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}
