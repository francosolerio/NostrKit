import Foundation
import CoreNostr
import OSLog

private let logger = Logger(subsystem: "NostrKit", category: "ResilientRelayService")

/// Enhanced relay service with automatic reconnection, heartbeat, and resubscription
public actor ResilientRelayService: RelayServiceProtocol {
    
    // MARK: - Properties
    
    public let url: String
    private let baseService: RelayService
    private let config: ResilienceConfiguration
    
    private let backoffManager: BackoffManager
    private let heartbeatManager: HeartbeatManager
    private let subscriptionManager: SubscriptionStateManager
    
    private var connectionState: ConnectionState = .disconnected
    private var reconnectionTask: Task<Void, Never>?
    
    // Statistics tracking
    private var stats = ResilienceStatistics()
    private var reconnectionTimes: [TimeInterval] = []
    private var connectionStartTime: Date?
    
    // Message stream
    private var messageContinuation: AsyncStream<RelayMessage>.Continuation?
    public let messages: AsyncStream<RelayMessage>
    
    // Relay capabilities (NIP-11)
    private var relayInfo: RelayInformation?
    
    // MARK: - Initialization
    
    public init(
        url: String,
        config: ResilienceConfiguration = .default,
        bufferSize: Int = 100
    ) {
        self.url = url
        self.config = config
        self.baseService = RelayService(url: url, bufferSize: bufferSize)
        self.backoffManager = BackoffManager(config: config)
        self.heartbeatManager = HeartbeatManager(config: config)
        self.subscriptionManager = SubscriptionStateManager()
        
        var continuation: AsyncStream<RelayMessage>.Continuation?
        self.messages = AsyncStream(bufferingPolicy: .bufferingNewest(bufferSize)) { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
        
        // Setup heartbeat timeout handler
        Task { [weak self] in
            guard let self else { return }
            await self.heartbeatManager.setTimeoutHandler { [weak self] in
                await self?.handleHeartbeatTimeout()
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func incrementHeartbeatSent() {
        stats = ResilienceStatistics(
            totalReconnections: stats.totalReconnections,
            successfulReconnections: stats.successfulReconnections,
            failedReconnections: stats.failedReconnections,
            totalHeartbeatsSent: stats.totalHeartbeatsSent + 1,
            totalHeartbeatsReceived: stats.totalHeartbeatsReceived,
            averageReconnectionTime: stats.averageReconnectionTime,
            lastDisconnection: stats.lastDisconnection,
            lastReconnection: stats.lastReconnection,
            currentUptime: stats.currentUptime
        )
    }
    
    // MARK: - Connection Management
    
    /// Connects to the relay with automatic resilience features
    public func connect() async throws {
        guard case .disconnected = connectionState else {
            logger.debug("Already connected or connecting to \(self.url)")
            return
        }
        
        connectionState = .connecting(attempt: 1)
        
        do {
            try await baseService.connect()
            await onConnectionEstablished()
            
            // Fetch relay information (NIP-11)
            await fetchRelayInformation()
            
            // Start monitoring connection
            await startMonitoring()
            
        } catch {
            logger.error("Initial connection failed: \(error)")
            connectionState = .failed(reason: error.localizedDescription)
            
            // Start reconnection attempts
            await startReconnection()
            
            throw error
        }
    }
    
    /// Disconnects from the relay
    public func disconnect() async {
        logger.info("Disconnecting from \(self.url)")
        
        // Cancel reconnection attempts
        reconnectionTask?.cancel()
        reconnectionTask = nil
        
        // Stop monitoring
        await heartbeatManager.stop()
        
        // Disconnect base service
        await baseService.disconnect()
        
        // Update state
        connectionState = .disconnected
        messageContinuation?.finish()
        
        // Clear subscriptions if not auto-resubscribing
        if !config.autoResubscribe {
            await subscriptionManager.clearAll()
        }
    }
    
    // MARK: - Message Sending
    
    public func publishEvent(_ event: NostrEvent) async throws {
        guard await ensureConnected() else {
            throw RelayServiceError.notConnected
        }
        
        try await baseService.publishEvent(event)
    }
    
    public func subscribe(id: String, filters: [Filter]) async throws {
        // Record subscription for resubscription
        await subscriptionManager.recordSubscription(id: id, filters: filters)
        
        guard await ensureConnected() else {
            throw RelayServiceError.notConnected
        }
        
        try await baseService.subscribe(id: id, filters: filters)
    }
    
    public func closeSubscription(id: String) async throws {
        await subscriptionManager.removeSubscription(id: id)
        
        guard await ensureConnected() else {
            throw RelayServiceError.notConnected
        }
        
        try await baseService.closeSubscription(id: id)
    }
    
    // MARK: - NIP-11 Relay Information
    
    /// Fetches relay information document (NIP-11)
    public func fetchRelayInformation() async {
        guard let infoURL = URL(string: url.replacingOccurrences(of: "wss://", with: "https://")
                                    .replacingOccurrences(of: "ws://", with: "http://")) else {
            return
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: infoURL)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                  contentType.contains("application/nostr+json") else {
                logger.debug("Relay does not support NIP-11")
                return
            }
            
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            relayInfo = try decoder.decode(RelayInformation.self, from: data)
            
            logger.info("Fetched relay info: \(self.relayInfo?.name ?? "Unknown")")
            
        } catch {
            logger.debug("Failed to fetch relay information: \(error)")
        }
    }
    
    /// Returns the relay's capabilities
    public var capabilities: RelayInformation? {
        relayInfo
    }
    
    /// Checks if the relay supports a specific NIP
    public func supportsNIP(_ nip: Int) -> Bool {
        relayInfo?.supportedNips?.contains(nip) ?? false
    }
    
    // MARK: - Private Methods
    
    private func startMonitoring() async {
        // Setup message forwarding
        Task {
            for await message in baseService.messages {
                await handleRelayMessage(message)
            }
            // Connection lost
            await handleConnectionLost()
        }
        
        // Start heartbeat monitoring
        await heartbeatManager.start(
            sendPing: { [weak self] in
                guard let self = self else { return }
                // Send a simple request as ping
                try await self.baseService.subscribe(
                    id: "ping-\(UUID().uuidString)",
                    filters: [Filter(limit: 0)]
                )
                await self.incrementHeartbeatSent()
            },
            checkConnection: { [weak self] in
                await self?.baseService.isConnected ?? false
            }
        )
    }
    
    private func handleRelayMessage(_ message: RelayMessage) async {
        // Forward message
        messageContinuation?.yield(message)
        
        // Handle specific message types
        switch message {
        case .eose(let subscriptionId):
            // Handle end of stored events
            if subscriptionId.starts(with: "ping-") {
                // This was a heartbeat ping, record pong
                await heartbeatManager.recordPong()
                stats = ResilienceStatistics(
                    totalHeartbeatsReceived: stats.totalHeartbeatsReceived + 1
                )
                // Close the ping subscription
                try? await baseService.closeSubscription(id: subscriptionId)
            }
            
        case .closed(let subscriptionId, let message):
            // Subscription was closed by relay
            logger.warning("Subscription \(subscriptionId) closed: \(message ?? "No reason provided")")
            await subscriptionManager.removeSubscription(id: subscriptionId)
            
        case .notice(let message):
            logger.info("Relay notice: \(message)")
            
        default:
            break
        }
    }
    
    private func handleConnectionLost() async {
        logger.warning("Connection lost to \(self.url)")
        
        let wasConnected = connectionState.isConnected
        connectionState = .disconnected
        
        if let startTime = connectionStartTime {
            let uptime = Date().timeIntervalSince(startTime)
            logger.info("Connection uptime was \(uptime) seconds")
        }
        
        stats = ResilienceStatistics(
            lastDisconnection: Date()
        )
        
        await heartbeatManager.stop()
        
        if wasConnected {
            await startReconnection()
        }
    }
    
    private func handleHeartbeatTimeout() async {
        logger.warning("Heartbeat timeout detected for \(self.url)")
        await handleConnectionLost()
    }
    
    private func startReconnection() async {
        guard reconnectionTask == nil else { return }
        
        reconnectionTask = Task {
            await performReconnection()
        }
    }
    
    private func performReconnection() async {
        await backoffManager.reset()
        
        while !Task.isCancelled {
            guard let delay = await backoffManager.nextDelay() else {
                logger.error("Max reconnection attempts reached for \(self.url)")
                connectionState = .failed(reason: "Max reconnection attempts reached")
                break
            }
            
            let attempt = await backoffManager.attempts
            let nextRetry = Date().addingTimeInterval(delay)
            
            connectionState = .reconnecting(attempt: attempt, nextRetry: nextRetry)
            logger.info("Reconnection attempt \(attempt) in \(delay) seconds")
            
            // Wait with jittered backoff
            try? await Task.sleep(for: .seconds(delay))
            
            guard !Task.isCancelled else { break }
            
            do {
                let reconnectStart = Date()
                try await baseService.connect()
                
                let reconnectTime = Date().timeIntervalSince(reconnectStart)
                reconnectionTimes.append(reconnectTime)
                
                await onConnectionEstablished()
                
                // Resubscribe if configured
                if config.autoResubscribe {
                    await resubscribeAll()
                }
                
                // Restart monitoring
                await startMonitoring()
                
                stats = ResilienceStatistics(
                    totalReconnections: stats.totalReconnections + 1,
                    successfulReconnections: stats.successfulReconnections + 1,
                    averageReconnectionTime: reconnectionTimes.reduce(0, +) / Double(reconnectionTimes.count),
                    lastReconnection: Date()
                )
                
                logger.info("Successfully reconnected to \(self.url)")
                break
                
            } catch {
                logger.error("Reconnection attempt \(attempt) failed: \(error)")
                stats = ResilienceStatistics(
                    totalReconnections: stats.totalReconnections + 1,
                    failedReconnections: stats.failedReconnections + 1
                )
            }
        }
        
        reconnectionTask = nil
    }
    
    private func onConnectionEstablished() async {
        connectionState = .connected(since: Date())
        connectionStartTime = Date()
        await backoffManager.reset()
        logger.info("Connected to \(self.url)")
    }
    
    private func resubscribeAll() async {
        let subscriptions = await subscriptionManager.getAllSubscriptions()
        
        guard !subscriptions.isEmpty else { return }
        
        logger.info("Resubscribing to \(subscriptions.count) subscriptions")
        
        for subscription in subscriptions {
            do {
                try await baseService.subscribe(id: subscription.id, filters: subscription.filters)
                logger.debug("Resubscribed to \(subscription.id)")
            } catch {
                logger.error("Failed to resubscribe to \(subscription.id): \(error)")
            }
        }
    }
    
    private func ensureConnected() async -> Bool {
        if connectionState.isConnected {
            return true
        }
        
        // Try to connect if disconnected
        if case .disconnected = connectionState {
            do {
                try await connect()
                return true
            } catch {
                return false
            }
        }
        
        // Wait a bit if reconnecting
        if case .reconnecting = connectionState {
            try? await Task.sleep(for: .seconds(0.5))
            return connectionState.isConnected
        }
        
        return false
    }
    
    // MARK: - Public API
    
    /// Current connection state
    public var state: ConnectionState {
        connectionState
    }
    
    /// Connection resilience statistics
    public var statistics: ResilienceStatistics {
        var currentStats = stats
        if let startTime = connectionStartTime, connectionState.isConnected {
            currentStats = ResilienceStatistics(
                currentUptime: Date().timeIntervalSince(startTime)
            )
        }
        return currentStats
    }
    
    /// Manually triggers a reconnection
    public func reconnect() async {
        await disconnect()
        try? await connect()
    }
    
    /// Prunes old subscriptions
    public func pruneSubscriptions(olderThan age: TimeInterval) async {
        await subscriptionManager.pruneOldSubscriptions(olderThan: age)
    }
}

// MARK: - RelayServiceProtocol

public protocol RelayServiceProtocol: Actor {
    var url: String { get }
    var messages: AsyncStream<RelayMessage> { get }
    
    func connect() async throws
    func disconnect() async
    func publishEvent(_ event: NostrEvent) async throws
    func subscribe(id: String, filters: [Filter]) async throws
    func closeSubscription(id: String) async throws
}

// MARK: - RelayInformation (NIP-11)
// RelayInformation is defined in RelayPool.swift