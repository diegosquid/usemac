import Foundation
import XCTest
@testable import MacUseEngine

let testExtensionOrigin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"

enum BridgeTestError: Error, LocalizedError {
    case invalidURL
    case unexpectedMessageType(expected: String, actual: String?)
    case invalidChallenge
    case serverProofMismatch
    case unexpectedFrameFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid bridge WebSocket URL"
        case .unexpectedMessageType(let expected, let actual):
            return "Expected WebSocket message type '\(expected)', got '\(actual ?? "<nil>")'"
        case .invalidChallenge:
            return "Challenge payload missing valid serverNonce or serverProof"
        case .serverProofMismatch:
            return "Bridge serverProof failed verification"
        case .unexpectedFrameFormat:
            return "Expected JSON object text frame on WebSocket"
        }
    }
}

func makeTemporaryBridgeKeyDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("macuse-bridge-key-\(UUID().uuidString)", isDirectory: true)
}

func waitForListeningPort(of bridge: ChromeExtensionBridge, timeoutMs: Int = 2000) async -> UInt16 {
    let iterations = max(1, timeoutMs / 15)
    for _ in 0..<iterations {
        let port = bridge.listeningPort
        if port != 0 {
            return port
        }
        try? await Task.sleep(nanoseconds: 15_000_000)
    }
    return bridge.listeningPort
}

func waitForBridgeCondition(
    timeoutMs: Int = 2000,
    intervalMs: Int = 15,
    _ condition: () -> Bool
) async -> Bool {
    let iterations = max(1, timeoutMs / max(1, intervalMs))
    for _ in 0..<iterations {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
    }
    return condition()
}

func openMockExtensionSocket(
    port: UInt16,
    origin: String? = testExtensionOrigin,
    session: URLSession? = nil
) throws -> URLSessionWebSocketTask {
    guard let url = URL(string: "ws://127.0.0.1:\(port)/macuse-bridge") else {
        throw BridgeTestError.invalidURL
    }
    var request = URLRequest(url: url)
    if let origin {
        request.setValue(origin, forHTTPHeaderField: "Origin")
    }
    let resolvedSession: URLSession
    let ownsSession: Bool
    if let session {
        resolvedSession = session
        ownsSession = false
    } else {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        resolvedSession = URLSession(configuration: config)
        ownsSession = true
    }
    let wsTask = resolvedSession.webSocketTask(with: request)
    wsTask.resume()
    if ownsSession {
        resolvedSession.finishTasksAndInvalidate()
    }
    return wsTask
}

func sendBridgeJSON(_ object: [String: Any], on wsTask: URLSessionWebSocketTask) async throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let text = String(data: data, encoding: .utf8) else {
        throw BridgeTestError.unexpectedFrameFormat
    }
    try await wsTask.send(.string(text))
}

func receiveBridgeJSON(from wsTask: URLSessionWebSocketTask) async throws -> [String: Any] {
    let message = try await wsTask.receive()
    guard case .string(let text) = message,
          let data = text.data(using: .utf8),
          let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BridgeTestError.unexpectedFrameFormat
    }
    return obj
}

func connectAuthenticatedMockExtension(
    port: UInt16,
    key: BridgeKey,
    profileName: String = "Chrome",
    tabCount: Int = 1,
    extensionVersion: String = "0.5.0"
) async throws -> URLSessionWebSocketTask {
    let wsTask = try openMockExtensionSocket(port: port, origin: testExtensionOrigin)
    do {
        let clientNonce = BridgeAuth.randomNonceHex()
        try await sendBridgeJSON([
            "type": "hello",
            "protocol": 2,
            "extensionVersion": extensionVersion,
            "profileName": profileName,
            "clientNonce": clientNonce,
            "hasKey": true
        ], on: wsTask)

        let challenge = try await receiveBridgeJSON(from: wsTask)
        guard (challenge["type"] as? String) == "challenge" else {
            throw BridgeTestError.unexpectedMessageType(expected: "challenge", actual: challenge["type"] as? String)
        }
        guard let serverNonce = challenge["serverNonce"] as? String,
              BridgeAuth.isNonceHex(serverNonce),
              let serverProof = challenge["serverProof"] as? String else {
            throw BridgeTestError.invalidChallenge
        }

        let expectedServerProof = BridgeAuth.serverProof(
            key: key,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        guard BridgeAuth.constantTimeEquals(serverProof, expectedServerProof) else {
            throw BridgeTestError.serverProofMismatch
        }

        let clientProof = BridgeAuth.clientProof(
            key: key,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        try await sendBridgeJSON([
            "type": "auth",
            "clientProof": clientProof
        ], on: wsTask)

        let ready = try await receiveBridgeJSON(from: wsTask)
        guard (ready["type"] as? String) == "ready" else {
            throw BridgeTestError.unexpectedMessageType(expected: "ready", actual: ready["type"] as? String)
        }

        try await sendBridgeJSON([
            "type": "profile_info",
            "profileName": profileName,
            "tabCount": tabCount
        ], on: wsTask)

        return wsTask
    } catch {
        wsTask.cancel(with: .goingAway, reason: nil)
        throw error
    }
}
