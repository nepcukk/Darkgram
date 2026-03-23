import Foundation
import Postbox
import SGSimpleSettings
import SwiftSignalKit

public enum DarkgramSyncConnectionState: String, Equatable {
    case disabled
    case noToken
    case connecting
    case registering
    case connected
    case disconnected
    case notRegistered
    case invalidConfiguration
    case invalidToken
}

public struct DarkgramSyncRuntimeState: Equatable {
    public var connectionState: DarkgramSyncConnectionState
    public var registerStatusCode: Int32?
    public var lastSentAt: Int64?
    public var lastReceivedAt: Int64?
    public var lastForceSyncAt: Int64?
    public var lastBootstrapSyncAt: Int64?
    public var lastEventType: String?
    public var activeAccountsCount: Int32
    public var reconnectAttempt: Int32
    public var queuedReadEventsCount: Int32
    public var deviceIdentifier: String

    public init(
        connectionState: DarkgramSyncConnectionState,
        registerStatusCode: Int32?,
        lastSentAt: Int64?,
        lastReceivedAt: Int64?,
        lastForceSyncAt: Int64?,
        lastBootstrapSyncAt: Int64?,
        lastEventType: String?,
        activeAccountsCount: Int32,
        reconnectAttempt: Int32,
        queuedReadEventsCount: Int32,
        deviceIdentifier: String
    ) {
        self.connectionState = connectionState
        self.registerStatusCode = registerStatusCode
        self.lastSentAt = lastSentAt
        self.lastReceivedAt = lastReceivedAt
        self.lastForceSyncAt = lastForceSyncAt
        self.lastBootstrapSyncAt = lastBootstrapSyncAt
        self.lastEventType = lastEventType
        self.activeAccountsCount = activeAccountsCount
        self.reconnectAttempt = reconnectAttempt
        self.queuedReadEventsCount = queuedReadEventsCount
        self.deviceIdentifier = deviceIdentifier
    }
}

private struct DarkgramSyncConfiguration {
    let server: String
    let token: String
    let useSecureConnection: Bool

    init?(settings: SGSimpleSettings) {
        let server = settings.darkgramSyncServerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "wss://", with: "")
            .replacingOccurrences(of: "ws://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let token = settings.darkgramSyncServerToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !server.isEmpty else {
            return nil
        }

        self.server = server
        self.token = token
        self.useSecureConnection = settings.darkgramSyncUseSecureConnection
    }

    var httpScheme: String {
        return self.useSecureConnection ? "https" : "http"
    }

    var websocketScheme: String {
        return self.useSecureConnection ? "wss" : "ws"
    }

    private func url(path: String, scheme: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = self.server

        if self.server.contains(":") {
            let parts = self.server.split(separator: ":", maxSplits: 1).map(String.init)
            components.host = parts.first
            if parts.count == 2 {
                components.port = Int(parts[1])
            }
        }

        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    var websocketURL: URL? {
        return self.url(path: "/sync/ws/v1", scheme: self.websocketScheme)
    }

    var userDataURL: URL? {
        return self.url(path: "/user/v1", scheme: self.httpScheme)
    }

    var registerDeviceURL: URL? {
        return self.url(path: "/sync/register/v1", scheme: self.httpScheme)
    }

    var forceSyncURL: URL? {
        return self.url(path: "/sync/force/v1", scheme: self.httpScheme)
    }

    var profileURLString: String? {
        guard !self.token.isEmpty else {
            return nil
        }
        return self.url(
            path: "/ui/profile",
            scheme: self.httpScheme,
            queryItems: [URLQueryItem(name: "token", value: self.token)]
        )?.absoluteString
    }
}

private struct DarkgramSyncAccountContext {
    let userId: Int64
    let postbox: Postbox
    let stateManager: AccountStateManager
}

private struct DarkgramSyncPendingReadKey: Hashable {
    let userId: Int64
    let dialogId: Int64
}

private struct DarkgramSyncPendingReadEvent {
    let userId: Int64
    let dialogId: Int64
    var untilId: Int32
    var unreadCount: Int32
}

public final class DarkgramSyncService: NSObject, URLSessionWebSocketDelegate {
    public static let shared = DarkgramSyncService()

    private let queue = DispatchQueue(label: "darkgram.sync.service")
    private let statePromise: ValuePromise<DarkgramSyncRuntimeState>

    private var stateValue: DarkgramSyncRuntimeState
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var reconnectWorkItem: DispatchWorkItem?
    private var accountContexts: [Int64: DarkgramSyncAccountContext] = [:]
    private var pendingReadEvents: [DarkgramSyncPendingReadKey: DarkgramSyncPendingReadEvent] = [:]
    private var didPerformBootstrapSyncForCurrentSocket = false

    private override init() {
        let settings = SGSimpleSettings.shared
        let deviceIdentifier: String
        if settings.darkgramSyncDeviceIdentifier.isEmpty {
            let generatedIdentifier = UUID().uuidString.lowercased()
            settings.darkgramSyncDeviceIdentifier = generatedIdentifier
            deviceIdentifier = generatedIdentifier
        } else {
            deviceIdentifier = settings.darkgramSyncDeviceIdentifier
        }

        let initialState = DarkgramSyncRuntimeState(
            connectionState: DarkgramSyncConnectionState(rawValue: settings.darkgramSyncConnectionState) ?? .notRegistered,
            registerStatusCode: settings.darkgramSyncRegisterStatusCode == 0 ? nil : settings.darkgramSyncRegisterStatusCode,
            lastSentAt: settings.darkgramSyncLastSentAt == 0 ? nil : settings.darkgramSyncLastSentAt,
            lastReceivedAt: settings.darkgramSyncLastReceivedAt == 0 ? nil : settings.darkgramSyncLastReceivedAt,
            lastForceSyncAt: nil,
            lastBootstrapSyncAt: nil,
            lastEventType: nil,
            activeAccountsCount: 0,
            reconnectAttempt: 0,
            queuedReadEventsCount: 0,
            deviceIdentifier: deviceIdentifier
        )

        self.stateValue = initialState
        self.statePromise = ValuePromise(initialState, ignoreRepeated: false)

        super.init()
    }

    public func stateSignal() -> Signal<DarkgramSyncRuntimeState, NoError> {
        return self.statePromise.get()
    }

    public func currentState() -> DarkgramSyncRuntimeState {
        return self.queue.sync {
            return self.stateValue
        }
    }

    public func refreshConnection() {
        self.queue.async {
            self.refreshConnectionSync()
        }
    }

    public func reconnect() {
        self.queue.async {
            self.refreshConnectionSync()
        }
    }

    public func profileURLString() -> String? {
        return DarkgramSyncConfiguration(settings: SGSimpleSettings.shared)?.profileURLString
    }

    public func setRegisteredAccounts(_ accounts: [(userId: Int64, postbox: Postbox, stateManager: AccountStateManager)]) {
        self.queue.async {
            var updatedContexts: [Int64: DarkgramSyncAccountContext] = [:]
            for account in accounts {
                updatedContexts[account.userId] = DarkgramSyncAccountContext(
                    userId: account.userId,
                    postbox: account.postbox,
                    stateManager: account.stateManager
                )
            }
            self.accountContexts = updatedContexts
            self.updateStateSync { state in
                state.activeAccountsCount = Int32(updatedContexts.count)
            }

            if updatedContexts.isEmpty {
                self.pendingReadEvents.removeAll()
                self.updateStateSync { state in
                    state.queuedReadEventsCount = 0
                }
            } else if self.stateValue.connectionState == .connected {
                self.didPerformBootstrapSyncForCurrentSocket = false
                self.performBootstrapSyncIfNeededSync()
            } else if SGSimpleSettings.shared.darkgramSyncEnabled && self.webSocketTask == nil {
                self.refreshConnectionSync()
            }
        }
    }

    public func forceSync(accountUserId: Int64) {
        self.queue.async {
            guard SGSimpleSettings.shared.darkgramSyncEnabled else {
                return
            }
            guard let configuration = DarkgramSyncConfiguration(settings: SGSimpleSettings.shared),
                  let url = configuration.forceSyncURL else {
                self.updateStateSync { state in
                    state.connectionState = .invalidConfiguration
                    state.lastEventType = "invalid_configuration"
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            self.applyHeaders(to: &request, token: configuration.token)

            let payload: [String: Any] = [
                "userId": accountUserId,
                "fromDate": 0
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

            let result = self.performDataRequestSync(request)
            guard let response = result.response as? HTTPURLResponse else {
                self.updateStateSync { state in
                    state.connectionState = .disconnected
                    state.lastEventType = "sync_force_error"
                }
                self.scheduleReconnectSync()
                return
            }

            if (200 ... 299).contains(response.statusCode) {
                let timestamp = self.currentTimestamp()
                self.updateStateSync { state in
                    state.lastSentAt = timestamp
                    state.lastForceSyncAt = timestamp
                    state.lastEventType = "sync_force"
                }
            } else {
                self.updateStateSync { state in
                    state.connectionState = .disconnected
                    state.lastEventType = "sync_force_error"
                }
            }
        }
    }

    public func syncRead(accountUserId: Int64, dialogId: Int64, untilId: Int32, unreadCount: Int32) {
        self.queue.async {
            guard SGSimpleSettings.shared.darkgramSyncEnabled else {
                return
            }

            let event = DarkgramSyncPendingReadEvent(
                userId: accountUserId,
                dialogId: dialogId,
                untilId: untilId,
                unreadCount: unreadCount
            )

            guard self.isSocketConnectedSync() else {
                self.enqueuePendingReadEventSync(event)
                if self.stateValue.connectionState != .connecting && self.stateValue.connectionState != .registering {
                    self.refreshConnectionSync()
                }
                return
            }

            self.sendSyncReadEventSync(event)
        }
    }

    private func refreshConnectionSync() {
        self.cancelReconnectSync()
        self.cancelSocketSync()
        self.didPerformBootstrapSyncForCurrentSocket = false

        guard SGSimpleSettings.shared.darkgramSyncEnabled else {
            self.pendingReadEvents.removeAll()
            self.updateStateSync { state in
                state.connectionState = .disabled
                state.reconnectAttempt = 0
                state.queuedReadEventsCount = 0
                state.lastEventType = "disabled"
            }
            return
        }

        guard let configuration = DarkgramSyncConfiguration(settings: SGSimpleSettings.shared),
              let userDataURL = configuration.userDataURL,
              let registerURL = configuration.registerDeviceURL,
              let websocketURL = configuration.websocketURL else {
            self.updateStateSync { state in
                state.connectionState = .invalidConfiguration
                state.lastEventType = "invalid_configuration"
            }
            return
        }

        guard !configuration.token.isEmpty else {
            self.updateStateSync { state in
                state.connectionState = .noToken
                state.lastEventType = "no_token"
            }
            return
        }

        self.updateStateSync { state in
            state.connectionState = .connecting
            state.lastEventType = "connect"
        }

        var userRequest = URLRequest(url: userDataURL)
        userRequest.httpMethod = "GET"
        self.applyHeaders(to: &userRequest, token: configuration.token)

        let userResult = self.performDataRequestSync(userRequest)
        guard let userResponse = userResult.response as? HTTPURLResponse else {
            self.updateStateSync { state in
                state.connectionState = .disconnected
                state.lastEventType = "connect_error"
            }
            self.scheduleReconnectSync()
            return
        }

        guard (200 ... 299).contains(userResponse.statusCode) else {
            self.updateStateSync { state in
                state.connectionState = userResponse.statusCode == 401 || userResponse.statusCode == 403 ? .invalidToken : .disconnected
                state.lastEventType = "user_check_\(userResponse.statusCode)"
            }
            if userResponse.statusCode != 401 && userResponse.statusCode != 403 {
                self.scheduleReconnectSync()
            }
            return
        }

        self.updateStateSync { state in
            state.connectionState = .registering
            state.lastEventType = "register"
        }

        var registerRequest = URLRequest(url: registerURL)
        registerRequest.httpMethod = "POST"
        self.applyHeaders(to: &registerRequest, token: configuration.token)
        registerRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let registerPayload: [String: Any] = [
            "name": ProcessInfo.processInfo.hostName,
            "identifier": self.stateValue.deviceIdentifier
        ]
        registerRequest.httpBody = try? JSONSerialization.data(withJSONObject: registerPayload)

        let registerResult = self.performDataRequestSync(registerRequest)
        let registerResponse = registerResult.response as? HTTPURLResponse
        self.updateStateSync { state in
            state.registerStatusCode = registerResponse.flatMap { Int32($0.statusCode) }
        }

        guard let response = registerResponse, (200 ... 299).contains(response.statusCode) else {
            self.updateStateSync { state in
                state.connectionState = .notRegistered
                state.lastEventType = "register_failed"
            }
            self.scheduleReconnectSync()
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var websocketRequest = URLRequest(url: websocketURL)
        self.applyHeaders(to: &websocketRequest, token: configuration.token)
        let task = session.webSocketTask(with: websocketRequest)
        self.webSocketSession = session
        self.webSocketTask = task
        task.resume()
        self.receiveNextMessageSync()
    }

    private func sendSyncReadEventSync(_ syncRead: DarkgramSyncPendingReadEvent) {
        let event: [String: Any] = [
            "type": "sync_read",
            "userId": syncRead.userId,
            "args": [
                "dialogId": syncRead.dialogId,
                "untilId": syncRead.untilId,
                "unread": syncRead.unreadCount
            ]
        ]
        self.sendEventSync(event, eventType: "sync_read")
    }

    private func enqueuePendingReadEventSync(_ event: DarkgramSyncPendingReadEvent) {
        let key = DarkgramSyncPendingReadKey(userId: event.userId, dialogId: event.dialogId)
        if var current = self.pendingReadEvents[key] {
            current.untilId = max(current.untilId, event.untilId)
            current.unreadCount = event.unreadCount
            self.pendingReadEvents[key] = current
        } else {
            self.pendingReadEvents[key] = event
        }
        self.updateStateSync { state in
            state.queuedReadEventsCount = Int32(self.pendingReadEvents.count)
            state.lastEventType = "queue_sync_read"
        }
    }

    private func flushPendingReadEventsSync() {
        guard self.isSocketConnectedSync(), !self.pendingReadEvents.isEmpty else {
            return
        }

        let events = self.pendingReadEvents.values.sorted { lhs, rhs in
            if lhs.userId != rhs.userId {
                return lhs.userId < rhs.userId
            }
            return lhs.dialogId < rhs.dialogId
        }
        self.pendingReadEvents.removeAll()
        self.updateStateSync { state in
            state.queuedReadEventsCount = 0
        }

        for event in events {
            self.sendSyncReadEventSync(event)
        }
    }

    private func performBootstrapSyncIfNeededSync() {
        guard self.isSocketConnectedSync(), !self.didPerformBootstrapSyncForCurrentSocket else {
            return
        }
        self.didPerformBootstrapSyncForCurrentSocket = true
        let timestamp = self.currentTimestamp()
        self.updateStateSync { state in
            state.lastBootstrapSyncAt = timestamp
            state.lastEventType = "bootstrap_sync"
        }

        for accountContext in self.accountContexts.values.sorted(by: { $0.userId < $1.userId }) {
            self.sendCurrentReadStatesSync(accountContext)
        }
    }

    private func isSocketConnectedSync() -> Bool {
        return self.webSocketTask != nil && self.stateValue.connectionState == .connected
    }

    private func sendEventSync(_ event: [String: Any], eventType: String) {
        guard let task = self.webSocketTask else {
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let string = String(data: data, encoding: .utf8) else {
            return
        }

        task.send(.string(string)) { [weak self] error in
            guard let self else {
                return
            }
            self.queue.async {
                if error == nil {
                    let timestamp = self.currentTimestamp()
                    self.updateStateSync { state in
                        state.lastSentAt = timestamp
                        state.lastEventType = eventType
                    }
                } else {
                    self.updateStateSync { state in
                        state.connectionState = .disconnected
                        state.lastEventType = "\(eventType)_error"
                    }
                    self.scheduleReconnectSync()
                }
            }
        }
    }

    private func receiveNextMessageSync() {
        guard let task = self.webSocketTask else {
            return
        }

        task.receive { [weak self] result in
            guard let self else {
                return
            }
            self.queue.async {
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        self.handleIncomingPayloadSync(Data(text.utf8))
                    case let .data(data):
                        self.handleIncomingPayloadSync(data)
                    @unknown default:
                        break
                    }
                    self.receiveNextMessageSync()
                case .failure:
                    self.updateStateSync { state in
                        state.connectionState = .disconnected
                        state.lastEventType = "socket_receive_error"
                    }
                    self.scheduleReconnectSync()
                }
            }
        }
    }

    private func handleIncomingPayloadSync(_ data: Data) {
        let timestamp = self.currentTimestamp()

        guard let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any] else {
            self.updateStateSync { state in
                state.lastReceivedAt = timestamp
                state.lastEventType = "payload_parse_error"
            }
            return
        }

        let eventType = (object["type"] as? String) ?? (object["name"] as? String) ?? "unknown"
        self.updateStateSync { state in
            state.lastReceivedAt = timestamp
            state.lastEventType = eventType
        }
        self.invokeHandlerSync(object)
    }

    private func invokeHandlerSync(_ object: [String: Any], inheritedUserId: Int64? = nil) {
        let eventName = (object["type"] as? String) ?? (object["name"] as? String) ?? ""
        let userId = (object["userId"] as? NSNumber)?.int64Value ?? inheritedUserId ?? 0

        guard !eventName.isEmpty else {
            return
        }
        guard let accountContext = self.accountContextForUserIdSync(userId) else {
            return
        }

        switch eventName {
        case "sync_force":
            self.sendCurrentReadStatesSync(accountContext)
        case "sync_batch":
            if let args = object["args"] as? [String: Any],
               let events = args["events"] as? [[String: Any]] {
                for event in events {
                    self.invokeHandlerSync(event, inheritedUserId: userId)
                }
            }
        case "sync_read":
            if let args = object["args"] as? [String: Any],
               let dialogId = (args["dialogId"] as? NSNumber)?.int64Value,
               let untilId = (args["untilId"] as? NSNumber)?.int32Value {
                let unread = (args["unread"] as? NSNumber)?.int32Value ?? 0
                self.applySyncReadLocallySync(accountContext: accountContext, dialogId: dialogId, untilId: untilId, unread: unread)
            }
        case "sync_force_finish":
            break
        default:
            break
        }
    }

    private func accountContextForUserIdSync(_ userId: Int64) -> DarkgramSyncAccountContext? {
        if let context = self.accountContexts[userId] {
            return context
        }
        if userId == 0 {
            return self.accountContexts.values.sorted(by: { $0.userId < $1.userId }).first
        }
        return nil
    }

    private func sendCurrentReadStatesSync(_ accountContext: DarkgramSyncAccountContext) {
        let _ = (accountContext.postbox.transaction { transaction -> [[String: Any]] in
            var peerIds = Set<PeerId>()
            var events: [[String: Any]] = []

            for groupId in [PeerGroupId.root, Namespaces.PeerGroup.archive] {
                for peer in transaction.getChatListPeers(groupId: groupId, filterPredicate: nil, additionalFilter: nil) {
                    if !peerIds.insert(peer.id).inserted {
                        continue
                    }
                    guard peer.id.namespace == Namespaces.Peer.CloudUser ||
                          peer.id.namespace == Namespaces.Peer.CloudGroup ||
                          peer.id.namespace == Namespaces.Peer.CloudChannel else {
                        continue
                    }
                    guard let states = transaction.getPeerReadStates(peer.id),
                          let cloudState = states.first(where: { $0.0 == Namespaces.Message.Cloud })?.1 else {
                        continue
                    }

                    let maxIncomingReadId: Int32
                    let unreadCount: Int32
                    switch cloudState {
                    case let .idBased(value, _, _, count, _):
                        maxIncomingReadId = value
                        unreadCount = count
                    case .indexBased:
                        continue
                    }

                    events.append([
                        "type": "sync_read",
                        "userId": accountContext.userId,
                        "args": [
                            "dialogId": peer.id.toInt64(),
                            "untilId": maxIncomingReadId,
                            "unread": unreadCount
                        ]
                    ])
                }
            }

            return events
        }).start(next: { [weak self] events in
            guard let self else {
                return
            }
            self.queue.async {
                guard !events.isEmpty else {
                    self.sendEventSync([
                        "type": "sync_force_finish",
                        "userId": accountContext.userId,
                        "args": [:]
                    ], eventType: "sync_force_finish")
                    self.flushPendingReadEventsSync()
                    return
                }

                self.sendEventSync([
                    "type": "sync_batch",
                    "userId": accountContext.userId,
                    "args": [
                        "events": events
                    ]
                ], eventType: "sync_batch")
                self.sendEventSync([
                    "type": "sync_force_finish",
                    "userId": accountContext.userId,
                    "args": [:]
                ], eventType: "sync_force_finish")
                self.flushPendingReadEventsSync()
            }
        })
    }

    private func applySyncReadLocallySync(accountContext: DarkgramSyncAccountContext, dialogId: Int64, untilId: Int32, unread: Int32) {
        let peerId = PeerId(dialogId)
        guard peerId.namespace == Namespaces.Peer.CloudUser ||
              peerId.namespace == Namespaces.Peer.CloudGroup ||
              peerId.namespace == Namespaces.Peer.CloudChannel else {
            return
        }

        let _ = (accountContext.postbox.transaction { transaction -> Bool in
            guard let peerReadStates = transaction.getPeerReadStates(peerId),
                  let currentState = peerReadStates.first(where: { $0.0 == Namespaces.Message.Cloud })?.1 else {
                return false
            }
            guard case let .idBased(currentMaxIncomingReadId, maxOutgoingReadId, currentMaxKnownId, currentUnreadCount, currentMarkedUnread) = currentState else {
                return false
            }
            guard currentUnreadCount > unread else {
                return false
            }

            let effectiveMaxIncomingReadId = max(currentMaxIncomingReadId, untilId)
            if effectiveMaxIncomingReadId > currentMaxIncomingReadId {
                transaction.applyIncomingReadMaxId(MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: effectiveMaxIncomingReadId))
            }

            var updatedStates = peerReadStates
            for i in 0 ..< updatedStates.count {
                guard updatedStates[i].0 == Namespaces.Message.Cloud else {
                    continue
                }
                updatedStates[i].1 = .idBased(
                    maxIncomingReadId: effectiveMaxIncomingReadId,
                    maxOutgoingReadId: maxOutgoingReadId,
                    maxKnownId: max(currentMaxKnownId, effectiveMaxIncomingReadId),
                    count: max(0, unread),
                    markedUnread: unread == 0 ? false : currentMarkedUnread
                )
                break
            }

            transaction.resetIncomingReadStates([peerId: Dictionary(updatedStates, uniquingKeysWith: { current, _ in current })])
            return true
        }).start(next: { applied in
            guard applied else {
                return
            }
            self.queue.async {
                accountContext.stateManager.notifyAppliedIncomingReadMessages([
                    MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: max(untilId, 1))
                ])
            }
        })
    }

    private func performDataRequestSync(_ request: URLRequest) -> (data: Data?, response: URLResponse?, error: Error?) {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return (resultData, resultResponse, resultError)
    }

    private func applyHeaders(to request: inout URLRequest, token: String) {
        request.setValue(Bundle.main.bundleIdentifier ?? "org.darkgram.ios", forHTTPHeaderField: "X-APP-PACKAGE")
        request.setValue(token, forHTTPHeaderField: "Authorization")
    }

    private func cancelSocketSync() {
        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.webSocketSession?.invalidateAndCancel()
        self.webSocketSession = nil
        self.didPerformBootstrapSyncForCurrentSocket = false
    }

    private func cancelReconnectSync() {
        self.reconnectWorkItem?.cancel()
        self.reconnectWorkItem = nil
    }

    private func scheduleReconnectSync() {
        self.cancelReconnectSync()
        guard SGSimpleSettings.shared.darkgramSyncEnabled else {
            return
        }

        var attempt: Int32 = 0
        self.updateStateSync { state in
            state.reconnectAttempt += 1
            attempt = state.reconnectAttempt
        }

        let delay = min(2.0 + Double(max(0, attempt - 1)) * 1.5, 12.0)
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshConnectionSync()
        }
        self.reconnectWorkItem = workItem
        self.queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func currentTimestamp() -> Int64 {
        return Int64(Date().timeIntervalSince1970)
    }

    private func persistStateSync(_ state: DarkgramSyncRuntimeState) {
        let settings = SGSimpleSettings.shared
        settings.darkgramSyncConnectionState = state.connectionState.rawValue
        settings.darkgramSyncRegisterStatusCode = state.registerStatusCode ?? 0
        settings.darkgramSyncLastSentAt = state.lastSentAt ?? 0
        settings.darkgramSyncLastReceivedAt = state.lastReceivedAt ?? 0
        settings.darkgramSyncDeviceIdentifier = state.deviceIdentifier
    }

    private func updateStateSync(_ update: (inout DarkgramSyncRuntimeState) -> Void) {
        var state = self.stateValue
        update(&state)
        guard state != self.stateValue else {
            return
        }

        self.stateValue = state
        self.persistStateSync(state)
        self.statePromise.set(state)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        self.queue.async {
            guard self.webSocketTask === webSocketTask else {
                return
            }
            self.updateStateSync { state in
                state.connectionState = .connected
                state.reconnectAttempt = 0
                state.lastEventType = "socket_open"
            }
            self.flushPendingReadEventsSync()
            self.performBootstrapSyncIfNeededSync()
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.queue.async {
            guard self.webSocketTask === webSocketTask else {
                return
            }
            self.updateStateSync { state in
                state.connectionState = .disconnected
                state.lastEventType = "socket_closed"
            }
            self.scheduleReconnectSync()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.queue.async {
            guard let completedTask = task as? URLSessionWebSocketTask,
                  let currentTask = self.webSocketTask,
                  currentTask === completedTask else {
                return
            }
            if error != nil {
                self.updateStateSync { state in
                    state.connectionState = .disconnected
                    state.lastEventType = "socket_complete_error"
                }
                self.scheduleReconnectSync()
            }
        }
    }
}
