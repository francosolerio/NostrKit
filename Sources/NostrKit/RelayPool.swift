import Foundation
import CoreNostr

/// Errors that can occur in relay operations
public enum RelayError: Error, LocalizedError {
    case timeout
    case eventRejected(reason: String?)
    case connectionFailed(Error)
    case notConnected
    
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Operation timed out"
        case .eventRejected(let reason):
            return "Event rejected: \(reason ?? "No reason provided")"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .notConnected:
            return "Not connected to relay"
        }
    }
}

/// A pool of relay connections that manages multiple relays with load balancing, health monitoring, and automatic failover.
///
/// The RelayPool provides high-level functionality for:
/// - Managing connections to multiple relays
/// - Automatic reconnection with exponential backoff
/// - Health monitoring and relay scoring
/// - Load balancing across healthy relays
/// - Broadcasting events to multiple relays
/// - Aggregating responses from multiple relays
///
/// ## Example
/// ```swift
/// let pool = RelayPool()
/// 
/// // Add relays
/// try await pool.addRelay(url: "wss://relay.damus.io")
/// try await pool.addRelay(url: "wss://relay.nostr.band")
/// 
/// // Connect to all relays
/// try await pool.connectAll()
/// 
/// // Publish an event to all connected relays
/// let event = try CoreNostr.createTextNote(content: "Hello, Nostr!", keyPair: keyPair)
/// let results = await pool.publish(event)
/// 
/// // Subscribe across all relays
/// let subscription = try await pool.subscribe(filters: [Filter(kinds: [.textNote])])
/// for await event in subscription.events {
///     print("Received event: \(event.content)")
/// }
/// ```
public actor RelayPool {
    
    // MARK: - Types
    
    /// Represents a relay in the pool with its connection and metadata
    public struct Relay: Sendable {
        /// The relay service instance
        public let service: RelayService
        
        /// The relay URL
        public let url: String
        
        /// Current connection state
        public var state: ConnectionState = .disconnected
        
        /// Health score (0.0 to 1.0, where 1.0 is perfectly healthy)
        public var healthScore: Double = 1.0
        
        /// Number of consecutive connection failures
        public var failureCount: Int = 0
        
        /// Last successful connection time
        public var lastConnectedAt: Date?
        
        /// Last error encountered
        public var lastError: Error?
        
        /// Relay information from NIP-11
        public var info: RelayInformation?
        
        /// Custom relay metadata (e.g., read/write preferences from NIP-65)
        public var metadata: RelayMetadata?
        
        /// Statistics for this relay
        public var stats: RelayStatistics = RelayStatistics()
    }
    
    /// Relay connection states
    public enum ConnectionState: String, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed
    }
    
    /// Relay metadata for NIP-65 support
    public struct RelayMetadata: Sendable {
        public let read: Bool
        public let write: Bool
        public let isPrimary: Bool
        
        public init(read: Bool = true, write: Bool = true, isPrimary: Bool = false) {
            self.read = read
            self.write = write
            self.isPrimary = isPrimary
        }
    }
    
    /// Statistics for relay performance monitoring
    public struct RelayStatistics: Sendable {
        public var eventsReceived: Int = 0
        public var eventsSent: Int = 0
        public var subscriptionCount: Int = 0
        public var averageResponseTime: TimeInterval = 0
        public var uptime: TimeInterval = 0
        public var lastActivity: Date?
    }
    
    /// Result of publishing an event to multiple relays
    public struct PublishResult: Sendable {
        public let relay: String
        public let success: Bool
        public let message: String?
        public let error: Error?
    }
    
    /// Options for relay pool behavior
    public struct Configuration: Sendable {
        /// Maximum number of relays to connect to simultaneously
        public let maxConnections: Int
        
        /// Initial reconnection delay in seconds
        public let initialReconnectDelay: TimeInterval
        
        /// Maximum reconnection delay in seconds
        public let maxReconnectDelay: TimeInterval
        
        /// Backoff multiplier for exponential backoff
        public let backoffMultiplier: Double
        
        /// Time to wait for relay responses before considering it unhealthy
        public let healthCheckTimeout: TimeInterval
        
        /// Minimum health score before relay is considered unhealthy
        public let minHealthScore: Double
        
        /// Whether to automatically reconnect on disconnection
        public let autoReconnect: Bool
        
        /// Whether to automatically discover relays from NIP-65
        public let autoDiscoverRelays: Bool
        
        public init(
            maxConnections: Int = 10,
            initialReconnectDelay: TimeInterval = 1.0,
            maxReconnectDelay: TimeInterval = 300.0,
            backoffMultiplier: Double = 2.0,
            healthCheckTimeout: TimeInterval = 5.0,
            minHealthScore: Double = 0.5,
            autoReconnect: Bool = true,
            autoDiscoverRelays: Bool = true
        ) {
            self.maxConnections = maxConnections
            self.initialReconnectDelay = initialReconnectDelay
            self.maxReconnectDelay = maxReconnectDelay
            self.backoffMultiplier = backoffMultiplier
            self.healthCheckTimeout = healthCheckTimeout
            self.minHealthScore = minHealthScore
            self.autoReconnect = autoReconnect
            self.autoDiscoverRelays = autoDiscoverRelays
        }
    }
    
    // MARK: - Properties
    
    /// All relays in the pool
    private var relays: [String: Relay] = [:]
    
    /// Active subscriptions
    private var subscriptions: [String: PoolSubscription] = [:]
    
    /// Pending OK responses tracked by relay URL and event ID
    private var pendingOKResponses: [String: [EventID: CheckedContinuation<PublishResult, Never>]] = [:]
    
    /// Configuration for the relay pool
    public let configuration: Configuration
    
    /// Delegate for relay pool events
    public weak var delegate: RelayPoolDelegate?
    
    /// Currently connected relays
    public var connectedRelays: [Relay] {
        relays.values.filter { $0.state == .connected }
    }
    
    /// Healthy relays (connected with good health score)
    public var healthyRelays: [Relay] {
        connectedRelays.filter { $0.healthScore >= configuration.minHealthScore }
    }
    
    // MARK: - Initialization
    
    /// Creates a new relay pool with the specified configuration
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }
    
    // MARK: - Relay Management
    
    /// Adds a relay to the pool
    /// - Parameters:
    ///   - url: The WebSocket URL of the relay
    ///   - metadata: Optional metadata for the relay
    /// - Returns: The added relay
    @discardableResult
    public func addRelay(url: String, metadata: RelayMetadata? = nil) throws -> Relay {
        guard Validation.isValidRelayURL(url) else {
            throw NostrError.invalidURI(uri: url, reason: "Invalid WebSocket URL format")
        }
        
        // Check if relay already exists
        if let existingRelay = relays[url] {
            return existingRelay
        }
        
        // Check max connections
        if relays.count >= configuration.maxConnections {
            throw NostrError.rateLimited(
                limit: configuration.maxConnections,
                resetTime: nil
            )
        }
        
        let service = RelayService(url: url)
        let relay = Relay(
            service: service,
            url: url,
            metadata: metadata
        )
        
        relays[url] = relay
        
        // Start monitoring this relay
        Task {
            await monitorRelay(url: url)
        }
        
        return relay
    }
    
    /// Removes a relay from the pool
    /// - Parameter url: The URL of the relay to remove
    public func removeRelay(url: String) async {
        guard let relay = relays[url] else { return }
        
        // Disconnect if connected
        if relay.state == .connected {
            await relay.service.disconnect()
        }
        
        // Clean up any pending OK responses
        if let pendingResponses = pendingOKResponses[url] {
            for (_, continuation) in pendingResponses {
                continuation.resume(returning: PublishResult(
                    relay: url,
                    success: false,
                    message: "Relay removed",
                    error: RelayError.notConnected
                ))
            }
            pendingOKResponses.removeValue(forKey: url)
        }
        
        // Remove from pool
        relays.removeValue(forKey: url)
        
        // Clean up subscriptions for this relay
        for subscription in subscriptions.values {
            await subscription.removeRelay(url: url)
        }
    }
    
    /// Connects to a specific relay
    /// - Parameter url: The URL of the relay to connect
    public func connect(to url: String) async throws {
        guard var relay = relays[url] else {
            throw NostrError.notFound(resource: "Relay with URL \(url)")
        }
        
        relay.state = .connecting
        relays[url] = relay
        
        do {
            try await relay.service.connect()
            
            relay.state = .connected
            relay.lastConnectedAt = Date()
            relay.failureCount = 0
            relay.lastError = nil
            relays[url] = relay
            
            // Fetch relay information
            await fetchRelayInformation(for: url)
            
            // Notify delegate
            await delegate?.relayPool(self, didConnectTo: url)
            
        } catch {
            relay.state = .failed
            relay.lastError = error
            relay.failureCount += 1
            relays[url] = relay
            
            // Update health score
            await updateHealthScore(for: url, eventType: .connectionFailure)
            
            // Schedule reconnection if enabled
            if configuration.autoReconnect {
                await scheduleReconnection(for: url)
            }
            
            throw error
        }
    }
    
    /// Connects to all relays in the pool
    public func connectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for url in relays.keys {
                group.addTask {
                    try? await self.connect(to: url)
                }
            }
        }
    }
    
    /// Disconnects from a specific relay
    /// - Parameter url: The URL of the relay to disconnect
    public func disconnect(from url: String) async {
        guard var relay = relays[url] else { return }
        
        await relay.service.disconnect()
        relay.state = .disconnected
        relays[url] = relay
        
        // Clean up any pending OK responses
        if let pendingResponses = pendingOKResponses[url] {
            for (_, continuation) in pendingResponses {
                continuation.resume(returning: PublishResult(
                    relay: url,
                    success: false,
                    message: "Relay disconnected",
                    error: RelayError.notConnected
                ))
            }
            pendingOKResponses.removeValue(forKey: url)
        }
        
        await delegate?.relayPool(self, didDisconnectFrom: url)
    }
    
    /// Disconnects from all relays
    public func disconnectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for url in relays.keys {
                group.addTask {
                    await self.disconnect(from: url)
                }
            }
        }
    }
    
    // MARK: - Event Publishing
    
    /// Publishes an event to all writable relays
    /// - Parameter event: The event to publish
    /// - Returns: Results from each relay
    public func publish(_ event: NostrEvent) async -> [PublishResult] {
        let writableRelays = healthyRelays.filter { relay in
            relay.metadata?.write ?? true
        }
        
        return await withTaskGroup(of: PublishResult.self) { group in
            for relay in writableRelays {
                group.addTask {
                    await self.publishToRelay(event, relay: relay)
                }
            }
            
            var results: [PublishResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    /// Publishes an event to specific relays
    /// - Parameters:
    ///   - event: The event to publish
    ///   - relayURLs: URLs of relays to publish to
    /// - Returns: Results from each relay
    public func publish(_ event: NostrEvent, to relayURLs: [String]) async -> [PublishResult] {
        let targetRelays = relayURLs.compactMap { url in
            relays[url]
        }.filter { relay in
            relay.state == .connected && (relay.metadata?.write ?? true)
        }
        
        return await withTaskGroup(of: PublishResult.self) { group in
            for relay in targetRelays {
                group.addTask {
                    await self.publishToRelay(event, relay: relay)
                }
            }
            
            var results: [PublishResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    // MARK: - Subscriptions
    
    /// Creates a subscription across all readable relays
    /// - Parameters:
    ///   - filters: Filters for the subscription
    ///   - id: Optional subscription ID (generated if not provided)
    /// - Returns: A pool subscription that aggregates events from all relays
    public func subscribe(
        filters: [Filter],
        id: String? = nil
    ) async throws -> PoolSubscription {
        let subscriptionId = id ?? UUID().uuidString
        
        let readableRelays = healthyRelays.filter { relay in
            relay.metadata?.read ?? true
        }
        
        guard !readableRelays.isEmpty else {
            throw NostrError.notFound(resource: "No readable relays available")
        }
        
        let subscription = PoolSubscription(
            id: subscriptionId,
            filters: filters,
            pool: self
        )
        
        subscriptions[subscriptionId] = subscription
        
        // Subscribe on all readable relays
        await subscription.subscribeToRelays(readableRelays.map { $0.url })
        
        return subscription
    }
    
    /// Closes a subscription
    /// - Parameter id: The subscription ID to close
    public func closeSubscription(id: String) async {
        guard let subscription = subscriptions[id] else { return }
        
        await subscription.close()
        subscriptions.removeValue(forKey: id)
    }
    
    // MARK: - Private Methods
    
    private func publishToRelay(_ event: NostrEvent, relay: Relay) async -> PublishResult {
        let startTime = Date()
        
        // Set up continuation for OK response
        let result = await withCheckedContinuation { continuation in
                // Store the continuation
                if pendingOKResponses[relay.url] == nil {
                    pendingOKResponses[relay.url] = [:]
                }
                pendingOKResponses[relay.url]?[event.id] = continuation
                
                // Send the event and handle timeout
                Task {
                    do {
                        try await relay.service.publishEvent(event)
                        
                        // Update statistics for sent event
                        if var updatedRelay = relays[relay.url] {
                            updatedRelay.stats.eventsSent += 1
                            updatedRelay.stats.lastActivity = Date()
                            relays[relay.url] = updatedRelay
                        }
                        
                        // Set a timeout for OK response
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            
                            // Check if continuation is still pending
                            if let pending = pendingOKResponses[relay.url]?.removeValue(forKey: event.id) {
                                // Timeout occurred
                                pending.resume(returning: PublishResult(
                                    relay: relay.url,
                                    success: false,
                                    message: "Timeout waiting for OK response",
                                    error: RelayError.timeout
                                ))
                            }
                        }
                        
                    } catch {
                        // Only resume if the continuation is still pending (hasn't been
                        // resumed by an OK response or timeout already). Fixes CASTAMATIC-1S0.
                        if let pending = pendingOKResponses[relay.url]?.removeValue(forKey: event.id) {
                            pending.resume(returning: PublishResult(
                                relay: relay.url,
                                success: false,
                                message: nil,
                                error: error
                            ))
                        }
                    }
                }
        }
        
        // Update response time statistics
        if result.success, var updatedRelay = relays[relay.url] {
            let responseTime = Date().timeIntervalSince(startTime)
            updatedRelay.stats.averageResponseTime = 
                (updatedRelay.stats.averageResponseTime + responseTime) / 2
            relays[relay.url] = updatedRelay
        } else {
            await updateHealthScore(for: relay.url, eventType: .publishFailure)
        }
        
        return result
    }
    
    private func monitorRelay(url: String) async {
        guard let relay = relays[url] else { return }

        for await message in relay.service.messages {
            // Update statistics
            if var updatedRelay = relays[url] {
                updatedRelay.stats.lastActivity = Date()

                switch message {
                case .event(_, let event):
                    updatedRelay.stats.eventsReceived += 1
                    // Log NWC response events for debugging
                    if event.kind == EventKind.nwcResponse.rawValue {
                        print("[RelayPool] NWC response received - id: \(event.id.prefix(16)), from: \(event.pubkey.prefix(16))...")
                    }
                case .notice(let notice):
                    print("[RelayPool] Notice from \(url): \(notice)")
                case .ok(let eventId, let accepted, let message):
                    // Check if we have a pending continuation for this event
                    if let continuation = pendingOKResponses[url]?.removeValue(forKey: eventId) {
                        // Resume the continuation with the result
                        continuation.resume(returning: PublishResult(
                            relay: url,
                            success: accepted,
                            message: message,
                            error: accepted ? nil : RelayError.eventRejected(reason: message)
                        ))
                    }

                    if !accepted {
                        print("[RelayPool] Event rejected by \(url): \(message ?? "No reason")")
                        await updateHealthScore(for: url, eventType: .eventRejected)
                    }
                case .closed(let subscriptionId, let message):
                    print("[RelayPool] Subscription \(subscriptionId) closed by \(url): \(message ?? "No reason")")
                default:
                    break
                }

                relays[url] = updatedRelay
            }

            // Forward message to relevant subscriptions
            for subscription in subscriptions.values {
                await subscription.handleMessage(message, from: url)
            }
        }
        
        // Connection dropped
        if var relay = relays[url] {
            relay.state = .disconnected
            relays[url] = relay
            
            if configuration.autoReconnect {
                await scheduleReconnection(for: url)
            }
        }
    }
    
    private func scheduleReconnection(for url: String) async {
        guard var relay = relays[url] else { return }
        
        relay.state = .reconnecting
        relays[url] = relay
        
        let delay = min(
            configuration.initialReconnectDelay * pow(configuration.backoffMultiplier, Double(relay.failureCount)),
            configuration.maxReconnectDelay
        )
        
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        
        if let currentRelay = relays[url], currentRelay.state == .reconnecting {
            try? await connect(to: url)
        }
    }
    
    private func updateHealthScore(for url: String, eventType: HealthEvent) async {
        guard var relay = relays[url] else { return }
        
        let impact: Double
        switch eventType {
        case .connectionSuccess:
            impact = 0.1
        case .connectionFailure:
            impact = -0.3
        case .publishSuccess:
            impact = 0.05
        case .publishFailure:
            impact = -0.1
        case .subscriptionSuccess:
            impact = 0.05
        case .subscriptionFailure:
            impact = -0.1
        case .eventRejected:
            impact = -0.05
        case .timeout:
            impact = -0.2
        }
        
        relay.healthScore = max(0, min(1, relay.healthScore + impact))
        relays[url] = relay
        
        // Notify delegate if relay became unhealthy
        if relay.healthScore < configuration.minHealthScore {
            await delegate?.relayPool(self, relay: url, becameUnhealthyWithScore: relay.healthScore)
        }
    }
    
    private func fetchRelayInformation(for url: String) async {
        guard var relay = relays[url] else { return }
        
        // Convert WebSocket URL to HTTP(S) URL
        var httpURL = url
        if httpURL.hasPrefix("wss://") {
            httpURL = httpURL.replacingOccurrences(of: "wss://", with: "https://")
        } else if httpURL.hasPrefix("ws://") {
            httpURL = httpURL.replacingOccurrences(of: "ws://", with: "http://")
        }
        
        // Ensure URL has trailing slash
        if !httpURL.hasSuffix("/") {
            httpURL += "/"
        }
        
        guard let infoURL = URL(string: httpURL) else { return }
        
        do {
            // Create request with Accept header for NIP-11
            var request = URLRequest(url: infoURL)
            request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10.0
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check response
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[RelayPool] Failed to fetch relay information from \(url)")
                return
            }
            
            // Decode relay information
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let relayInfo = try decoder.decode(RelayInformation.self, from: data)
            
            // Update relay with information
            relay.info = relayInfo
            relays[url] = relay
            
            print("[RelayPool] Fetched relay information for \(url): \(relayInfo.name ?? "Unknown")")
            
        } catch {
            print("[RelayPool] Error fetching relay information from \(url): \(error)")
        }
    }
    
    private enum HealthEvent {
        case connectionSuccess
        case connectionFailure
        case publishSuccess
        case publishFailure
        case subscriptionSuccess
        case subscriptionFailure
        case eventRejected
        case timeout
    }
}

// MARK: - PoolSubscription

/// A subscription that aggregates events from multiple relays
public actor PoolSubscription {
    public let id: String
    public let filters: [Filter]
    private weak var pool: RelayPool?
    private var relaySubscriptions: [String: Bool] = [:] // URL -> isEOSE
    private var seenEventIds: Set<String> = []
    private let eventSubject = AsyncStream<NostrEvent>.makeStream()
    
    /// Stream of deduplicated events from all relays
    public var events: AsyncStream<NostrEvent> {
        eventSubject.stream
    }
    
    init(id: String, filters: [Filter], pool: RelayPool) {
        self.id = id
        self.filters = filters
        self.pool = pool
    }
    
    func subscribeToRelays(_ urls: [String]) async {
        guard let pool = pool else { return }
        
        for url in urls {
            guard let relay = await pool.getRelay(url),
                  relay.state == .connected else { continue }
            
            do {
                try await relay.service.subscribe(id: id, filters: filters)
                relaySubscriptions[url] = false
            } catch {
                print("[PoolSubscription] Failed to subscribe to \(url): \(error)")
            }
        }
    }
    
    func handleMessage(_ message: RelayMessage, from url: String) async {
        switch message {
        case .event(let subId, let event):
            if subId == id {
                // Deduplicate events
                if !seenEventIds.contains(event.id) {
                    seenEventIds.insert(event.id)
                    // Log NWC response events for debugging
                    if event.kind == EventKind.nwcResponse.rawValue {
                        print("[PoolSubscription] Yielding NWC response - subId: \(id.prefix(8)), eventId: \(event.id.prefix(16))")
                    }
                    eventSubject.continuation.yield(event)
                }
            }

        case .eose(let subId):
            if subId == id {
                relaySubscriptions[url] = true

                // Check if all relays have sent EOSE
                let allEOSE = relaySubscriptions.values.allSatisfy { $0 }
                if allEOSE {
                    // All relays have sent their stored events
                    await pool?.delegate?.relayPool(pool!, subscription: id, receivedEOSEFromAllRelays: true)
                }
            }

        default:
            break
        }
    }
    
    func removeRelay(url: String) async {
        relaySubscriptions.removeValue(forKey: url)
    }
    
    func close() async {
        guard let pool = pool else { return }
        
        // Close subscription on all relays
        for url in relaySubscriptions.keys {
            if let relay = await pool.getRelay(url),
               relay.state == .connected {
                try? await relay.service.closeSubscription(id: id)
            }
        }
        
        eventSubject.continuation.finish()
    }
}

// MARK: - RelayPoolDelegate

/// Delegate protocol for relay pool events
public protocol RelayPoolDelegate: AnyObject, Sendable {
    /// Called when a relay connects successfully
    func relayPool(_ pool: RelayPool, didConnectTo relay: String) async
    
    /// Called when a relay disconnects
    func relayPool(_ pool: RelayPool, didDisconnectFrom relay: String) async
    
    /// Called when a relay becomes unhealthy
    func relayPool(_ pool: RelayPool, relay: String, becameUnhealthyWithScore score: Double) async
    
    /// Called when all relays in a subscription have sent EOSE
    func relayPool(_ pool: RelayPool, subscription: String, receivedEOSEFromAllRelays: Bool) async
}

// MARK: - Helper Extensions

extension RelayPool {
    /// Gets a relay by URL (internal use)
    func getRelay(_ url: String) -> Relay? {
        relays[url]
    }
}

// MARK: - Relay Information (NIP-11)

/// Information about a relay's capabilities and limitations
public struct RelayInformation: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let pubkey: String?
    public let contact: String?
    public let supportedNips: [Int]?
    public let software: String?
    public let version: String?
    public let limitation: Limitation?
    
    public struct Limitation: Codable, Sendable {
        public let maxMessageLength: Int?
        public let maxSubscriptions: Int?
        public let maxFilters: Int?
        public let maxLimit: Int?
        public let maxSubidLength: Int?
        public let maxEventTags: Int?
        public let maxContentLength: Int?
        public let minPowDifficulty: Int?
        public let authRequired: Bool?
        public let paymentRequired: Bool?
        public let createdAtLowerLimit: Int?
        public let createdAtUpperLimit: Int?
        
        enum CodingKeys: String, CodingKey {
            case maxMessageLength = "max_message_length"
            case maxSubscriptions = "max_subscriptions"
            case maxFilters = "max_filters"
            case maxLimit = "max_limit"
            case maxSubidLength = "max_subid_length"
            case maxEventTags = "max_event_tags"
            case maxContentLength = "max_content_length"
            case minPowDifficulty = "min_pow_difficulty"
            case authRequired = "auth_required"
            case paymentRequired = "payment_required"
            case createdAtLowerLimit = "created_at_lower_limit"
            case createdAtUpperLimit = "created_at_upper_limit"
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case name
        case description
        case pubkey
        case contact
        case supportedNips = "supported_nips"
        case software
        case version
        case limitation
    }
}