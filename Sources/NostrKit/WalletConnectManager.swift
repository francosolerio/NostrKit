//
//  WalletConnectManager.swift
//  NostrKit
//
//  Created by Nostr Team on 1/12/25.
//

import Foundation
import CoreNostr
import Combine
import OSLog

// MARK: - RelayPool Conformance

extension RelayPool: WalletRelayPool {
    func addRelay(url: String) async throws {
        _ = try self.addRelay(url: url, metadata: nil)
    }
    
    func walletSubscribe(filters: [Filter], id: String?) async throws -> WalletSubscription {
        let poolSubscription = try await subscribe(filters: filters, id: id)
        let stream = await poolSubscription.events
        return WalletSubscription(id: poolSubscription.id, events: stream)
    }
}

// MARK: - KeychainWrapper conformance

extension KeychainWrapper: WalletStorage {
    func store(_ data: Data, forKey key: String) async throws {
        try self.save(data, forKey: key, requiresBiometrics: false)
    }
    
    func load(key: String) async throws -> Data {
        try self.load(key: key, context: nil)
    }
    
    func remove(key: String) async throws {
        try self.delete(key: key)
    }
}

// MARK: - Supporting Types

protocol WalletStorage: Actor {
    func store(_ data: Data, forKey key: String) async throws
    func load(key: String) async throws -> Data
    func remove(key: String) async throws
}

protocol WalletRelayPool: Actor {
    func addRelay(url: String) async throws
    func connectAll() async
    func publish(_ event: NostrEvent) async -> [RelayPool.PublishResult]
    func walletSubscribe(filters: [Filter], id: String?) async throws -> WalletSubscription
    func closeSubscription(id: String) async
    func disconnectAll() async
}

/// Minimal subscription wrapper to decouple WalletConnectManager from the underlying relay pool implementation.
public struct WalletSubscription: Sendable {
    public let id: String
    public let events: AsyncStream<NostrEvent>
}

/// Simple token bucket rate limiter used to throttle NWC requests per wallet.
private struct NWCRateLimiter {
    private let maxTokens: Double
    private let refillInterval: TimeInterval
    private var availableTokens: Double
    private var lastRefill: Date
    
    init(maxRequestsPerMinute: Int) {
        self.maxTokens = Double(maxRequestsPerMinute)
        self.refillInterval = 60.0
        self.availableTokens = Double(maxRequestsPerMinute)
        self.lastRefill = Date()
    }
    
    mutating func consume() -> Bool {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        if elapsed > 0 {
            let refill = (elapsed / refillInterval) * maxTokens
            availableTokens = min(maxTokens, availableTokens + refill)
            lastRefill = now
        }
        
        if availableTokens >= 1 {
            availableTokens -= 1
            return true
        }
        return false
    }
}

/// Manages Lightning wallet connections using the Nostr Wallet Connect protocol (NIP-47).
///
/// `WalletConnectManager` provides a complete interface for integrating Lightning payments
/// into your Nostr application. It handles connection management, payment operations,
/// and real-time notifications from wallet services.
///
/// ## Overview
///
/// The manager maintains persistent connections to NWC-compatible wallet services through
/// Nostr relays, enabling seamless Lightning Network integration. All connections are
/// stored securely in the iOS Keychain and automatically restored on app launch.
///
/// ### Key Features
/// - Multiple wallet connection management
/// - Secure connection storage in Keychain
/// - Real-time payment notifications
/// - Automatic reconnection handling
/// - Support for both NIP-04 and NIP-44 encryption
///
/// ## Example Usage
///
/// ```swift
/// @StateObject private var walletManager = WalletConnectManager()
///
/// // Connect to a wallet
/// try await walletManager.connect(
///     uri: "nostr+walletconnect://pubkey?relay=wss://relay.com&secret=..."
/// )
///
/// // Pay an invoice
/// let result = try await walletManager.payInvoice("lnbc1000n1...")
/// print("Payment completed with preimage: \(result.preimage)")
///
/// // Check balance
/// let balance = try await walletManager.getBalance()
/// print("Balance: \(balance) millisats")
/// ```
///
/// ## Topics
///
/// ### Essentials
/// - ``connect(uri:alias:)``
/// - ``disconnect()``
/// - ``payInvoice(_:amount:)``
/// - ``getBalance()``
///
/// ### Connection Management
/// - ``connections``
/// - ``activeConnection``
/// - ``connectionState``
/// - ``switchConnection(to:)``
/// - ``removeConnection(_:)``
/// - ``reconnect()``
///
/// ### Payment Operations
/// - ``makeInvoice(amount:description:expiry:)``
/// - ``listTransactions(from:until:limit:)``
///
/// ### State Observation
/// - ``balance``
/// - ``recentTransactions``
/// - ``isLoading``
/// - ``lastError``
///
/// ### Utility Methods
/// - ``supportsMethod(_:)``
/// - ``supportsNotifications``
/// - ``preferredEncryption``
@MainActor
@Observable
public class WalletConnectManager {
    
    // MARK: - Types
    
    /// Represents a persistent wallet connection with its metadata and capabilities.
    ///
    /// Each connection stores the NWC URI components and tracks usage statistics.
    /// Connections are automatically persisted to the Keychain for secure storage.
    public struct WalletConnection: Codable, Identifiable {
        /// Unique identifier for this connection.
        public let id: String
        
        /// The parsed NWC connection URI containing wallet pubkey, relays, and secret.
        public let uri: NWCConnectionURI
        
        /// Optional human-readable alias for this wallet connection.
        public let alias: String?
        
        /// Timestamp when this connection was first established.
        public let createdAt: Date
        
        /// Timestamp of the most recent successful operation with this wallet.
        public var lastUsedAt: Date?
        
        /// Wallet capabilities including supported methods and encryption schemes.
        ///
        /// This is populated by querying the wallet's info event (kind 13194) after connection.
        public var capabilities: NWCInfo?
        
        /// Creates a new wallet connection.
        ///
        /// - Parameters:
        ///   - uri: The parsed NWC connection URI
        ///   - alias: Optional human-readable name for this connection
        public init(uri: NWCConnectionURI, alias: String? = nil) {
            self.id = UUID().uuidString
            self.uri = uri
            self.alias = alias
            self.createdAt = Date()
        }
    }
    
    /// The result of a successful Lightning payment.
    ///
    /// Contains the payment proof (preimage) and optional fee information.
    public struct PaymentResult: Sendable {
        /// The payment preimage serving as proof of payment.
        ///
        /// This 32-byte value is the cryptographic proof that the payment was completed.
        public let preimage: String
        
        /// The amount of fees paid in millisatoshis, if reported by the wallet.
        public let feesPaid: Int64?
        
        /// The payment hash, if provided by the wallet.
        public let paymentHash: String?
    }
    
    /// Represents the current state of the wallet connection.
    ///
    /// Use this to update your UI based on connection status.
    public enum ConnectionState {
        /// No active wallet connection.
        case disconnected
        
        /// Currently establishing connection to wallet service.
        case connecting
        
        /// Successfully connected and ready for operations.
        case connected
        
        /// Connection attempt failed with an error.
        case failed(Error)
    }
    
    // MARK: - Published Properties
    
    /// All wallet connections stored in the Keychain.
    ///
    /// This array persists across app launches and is automatically loaded on initialization.
    public private(set) var connections: [WalletConnection] = []
    
    /// The currently active wallet connection used for payment operations.
    ///
    /// Set this to `nil` to disconnect, or use ``switchConnection(to:)`` to change wallets.
    public var activeConnection: WalletConnection?
    
    /// The current connection state of the active wallet.
    ///
    /// Observe this property to update your UI based on connection status.
    public private(set) var connectionState: ConnectionState = .disconnected
    
    /// The last known wallet balance in millisatoshis.
    ///
    /// This value is updated when calling ``getBalance()`` or when receiving payment notifications.
    /// - Note: 1000 millisats = 1 satoshi
    public private(set) var balance: Int64?
    
    /// Recent transactions fetched from the wallet.
    ///
    /// Updated by calling ``listTransactions(from:until:limit:)`` or via notifications.
    public private(set) var recentTransactions: [NWCTransaction] = []
    
    /// Indicates whether an operation is currently in progress.
    ///
    /// Use this to show loading indicators in your UI.
    public private(set) var isLoading = false
    
    /// The most recent error that occurred, if any.
    ///
    /// This is set when operations fail and can be used for error reporting.
    public private(set) var lastError: Error?
    
    // MARK: - Private Properties
    
    private let keychain: any WalletStorage
    private let relayPool: any WalletRelayPool
    private var subscriptions: [String: String] = [:] // requestId -> subscriptionId
    private var notificationSubscription: String?
    private var notificationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var processedResponses: Set<String> = []
    private var processedNotifications: Set<String> = []
    private var rateLimiter: NWCRateLimiter
    
    // Reconnection state
    private var reconnectionTask: Task<Void, Never>?
    private var reconnectionAttempts: Int = 0
    private var isAutoReconnectEnabled: Bool = true
    
    /// Maximum age for processed response/notification IDs before cleanup (1 hour)
    private static let processedIdMaxAge: TimeInterval = 3600
    
    /// Maximum reconnection attempts before giving up
    private static let maxReconnectionAttempts: Int = 10
    
    /// Base delay for exponential backoff (1 second)
    private static let baseReconnectionDelay: TimeInterval = 1.0
    
    /// Maximum delay between reconnection attempts (5 minutes)
    private static let maxReconnectionDelay: TimeInterval = 300.0
    
    // MARK: - Constants
    
    private static let keychainService = "com.nostrkit.nwc"
    private static let connectionsKey = "wallet_connections"
    private static let activeConnectionKey = "active_connection"
    
    // MARK: - Initialization
    
    /// Creates a new wallet connect manager instance.
    ///
    /// The manager automatically loads any previously saved connections from the Keychain
    /// on initialization. No manual setup is required.
    ///
    /// - Note: The manager must be used on the main actor for SwiftUI compatibility.
    public init(maxRequestsPerMinute: Int = 30) {
        self.keychain = KeychainWrapper(service: Self.keychainService)
        self.relayPool = RelayPool()
        self.rateLimiter = NWCRateLimiter(maxRequestsPerMinute: maxRequestsPerMinute)
        
        Task {
            await loadConnections()
        }
    }
    
    // Internal initializer for testing/custom injection
    init(
        relayPool: any WalletRelayPool,
        keychain: any WalletStorage,
        seedConnections: [WalletConnection]? = nil,
        activeConnectionId: String? = nil,
        maxRequestsPerMinute: Int = 30
    ) {
        self.keychain = keychain
        self.relayPool = relayPool
        self.rateLimiter = NWCRateLimiter(maxRequestsPerMinute: maxRequestsPerMinute)
        
        if let seedConnections {
            self.connections = seedConnections
            if let activeId = activeConnectionId {
                self.activeConnection = seedConnections.first(where: { $0.id == activeId })
            } else {
                self.activeConnection = seedConnections.first
            }
        }
    }
    
    // MARK: - Connection Management
    
    /// Establishes a connection to a Lightning wallet using a NWC URI.
    ///
    /// This method connects to the specified wallet service through the provided relays,
    /// fetches the wallet's capabilities, and stores the connection securely in the Keychain.
    /// If this is the first connection, it automatically becomes the active connection.
    ///
    /// - Parameters:
    ///   - uri: A NWC connection URI in the format `nostr+walletconnect://pubkey?relay=...&secret=...`
    ///   - alias: An optional human-readable name for this wallet connection
    ///
    /// - Throws:
    ///   - ``NWCError`` with code `.other` if the URI is invalid
    ///   - ``RelayError`` if connection to relays fails
    ///   - Other network-related errors
    ///
    /// - Important: The connection URI contains sensitive information and should be obtained
    ///   securely from the user's wallet provider.
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     try await walletManager.connect(
    ///         uri: "nostr+walletconnect://abc123...?relay=wss://relay.getalby.com/v1&secret=...",
    ///         alias: "My Alby Wallet"
    ///     )
    ///     print("Connected to wallet!")
    /// } catch {
    ///     print("Connection failed: \(error)")
    /// }
    /// ```
    ///
    /// - Note: The connection process includes:
    ///   1. Parsing and validating the URI
    ///   2. Connecting to specified relays
    ///   3. Fetching wallet capabilities
    ///   4. Storing connection securely
    ///   5. Subscribing to payment notifications
    public func connect(uri: String, alias: String? = nil) async throws {
        guard let nwcURI = NWCConnectionURI(from: uri) else {
            throw NWCError(code: .other, message: "Invalid NWC URI")
        }

        // Check if already connected to this wallet and relay is connected
        if let existingIndex = connections.firstIndex(where: { $0.uri.walletPubkey == nwcURI.walletPubkey }) {
            // Already have a connection to this wallet
            if activeConnection?.uri.walletPubkey == nwcURI.walletPubkey,
               case .connected = connectionState {
                // Already active and connected, nothing to do
                return
            }

            // Reconnect to existing connection but refresh capabilities
            connectionState = .connecting
            isLoading = true
            defer { isLoading = false }

            do {
                // Connect to relays
                for relay in nwcURI.relays {
                    try await relayPool.addRelay(url: relay)
                }
                await relayPool.connectAll()

                // Refresh capabilities (they may be stale from keychain)
                if let info = try await fetchWalletInfo(walletPubkey: nwcURI.walletPubkey) {
                    connections[existingIndex].capabilities = info
                    await saveConnections()
                }

                // Set as active
                activeConnection = connections[existingIndex]
                await saveActiveConnection()

                connectionState = .connected
                await subscribeToNotifications()
            } catch {
                connectionState = .failed(error)
                lastError = error
                throw error
            }
            return
        }

        connectionState = .connecting
        isLoading = true
        defer { isLoading = false }

        do {
            // Add relays to the pool
            for relay in nwcURI.relays {
                try await relayPool.addRelay(url: relay)
            }

            // Connect to relays
            await relayPool.connectAll()

            // Create and store connection
            var connection = WalletConnection(uri: nwcURI, alias: alias)

            // Fetch wallet capabilities
            if let info = try await fetchWalletInfo(walletPubkey: nwcURI.walletPubkey) {
                connection.capabilities = info
            }

            // Store connection
            connections.append(connection)
            await saveConnections()

            // Always set as active for new connections
            activeConnection = connection
            await saveActiveConnection()

            connectionState = .connected

            // Subscribe to notifications
            await subscribeToNotifications()

        } catch {
            connectionState = .failed(error)
            lastError = error
            throw error
        }
    }
    
    /// Disconnects from the currently active wallet.
    ///
    /// This method closes all active subscriptions, disconnects from relays,
    /// and clears the active connection. The connection remains stored and can
    /// be reactivated later using ``reconnect()`` or ``switchConnection(to:)``.
    ///
    /// - Note: This does not remove the wallet from stored connections.
    ///   Use ``removeConnection(_:)`` to permanently remove a wallet.
    ///
    /// ## Example
    ///
    /// ```swift
    /// await walletManager.disconnect()
    /// // The wallet is now disconnected but still saved
    /// ```
    public func disconnect() async {
        connectionState = .disconnected
        
        // Cancel notification listening task
        notificationTask?.cancel()
        notificationTask = nil
        
        // Cancel all subscriptions
        for subscriptionId in subscriptions.values {
            await relayPool.closeSubscription(id: subscriptionId)
        }
        subscriptions.removeAll()
        
        if let notificationSubscription = notificationSubscription {
            await relayPool.closeSubscription(id: notificationSubscription)
            self.notificationSubscription = nil
        }
        
        // Disconnect from relays
        await relayPool.disconnectAll()
        
        // Clear active connection
        activeConnection = nil
        await saveActiveConnection()
        
        // Clear cached data
        balance = nil
        recentTransactions = []
        
        // Clear processed ID caches to prevent memory leaks
        processedResponses.removeAll()
        processedNotifications.removeAll()
    }
    
    /// Permanently removes a wallet connection from storage.
    ///
    /// This removes the connection from the Keychain and disconnects if it's currently active.
    ///
    /// - Parameter connection: The wallet connection to remove
    ///
    /// - Note: This action cannot be undone. The user will need to re-enter
    ///   the connection URI to use this wallet again.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let walletToRemove = walletManager.connections.first {
    ///     await walletManager.removeConnection(walletToRemove)
    /// }
    /// ```
    public func removeConnection(_ connection: WalletConnection) async {
        connections.removeAll { $0.id == connection.id }
        await saveConnections()
        
        if activeConnection?.id == connection.id {
            await disconnect()
        }
    }
    
    /// Switches the active wallet to a different stored connection.
    ///
    /// This method disconnects from the current wallet (if any) and connects
    /// to the specified wallet connection.
    ///
    /// - Parameter connection: The wallet connection to activate
    ///
    /// - Throws:
    ///   - ``NWCError`` if the connection is not found in stored connections
    ///   - Connection errors if establishing the new connection fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let secondWallet = walletManager.connections[1] {
    ///     try await walletManager.switchConnection(to: secondWallet)
    /// }
    /// ```
    public func switchConnection(to connection: WalletConnection) async throws {
        guard connections.contains(where: { $0.id == connection.id }) else {
            throw NWCError(code: .other, message: "Connection not found")
        }
        
        // Disconnect current
        await disconnect()
        
        // Set new active connection
        activeConnection = connection
        await saveActiveConnection()
        
        // Connect to new wallet
        try await reconnect()
    }
    
    /// Reconnects to the currently active wallet.
    ///
    /// Use this method to re-establish a connection after network issues
    /// or when returning from background.
    ///
    /// - Throws:
    ///   - ``NWCError`` if no active connection is set
    ///   - Connection errors if establishing the connection fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// // After network recovery
    /// do {
    ///     try await walletManager.reconnect()
    /// } catch {
    ///     print("Reconnection failed: \(error)")
    /// }
    /// ```
    public func reconnect() async throws {
        guard let connection = activeConnection else {
            throw NWCError(code: .other, message: "No active connection")
        }
        
        connectionState = .connecting
        
        do {
            // Add relays to the pool
            for relay in connection.uri.relays {
                try await relayPool.addRelay(url: relay)
            }
            
            // Connect to relays
            await relayPool.connectAll()
            
            connectionState = .connected
            
            // Subscribe to notifications
            await subscribeToNotifications()
            
        } catch {
            connectionState = .failed(error)
            lastError = error
            throw error
        }
    }
    
    // MARK: - Payment Operations
    
    /// Pays a Lightning invoice using the connected wallet.
    ///
    /// This method sends a payment request to the connected wallet service and waits
    /// for confirmation. The wallet must have sufficient balance and the invoice must be valid.
    ///
    /// - Parameters:
    ///   - invoice: A BOLT11 Lightning invoice string (e.g., "lnbc1000n1...")
    ///   - amount: Optional amount override in millisatoshis. Only valid for zero-amount invoices.
    ///
    /// - Returns: A ``PaymentResult`` containing the payment preimage and optional fee information.
    ///
    /// - Throws:
    ///   - ``NWCError/insufficientBalance``: The wallet doesn't have enough funds
    ///   - ``NWCError/paymentFailed``: The payment could not be completed
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/rateLimited``: Too many requests in a short time
    ///
    /// - Important: Always check the wallet balance before attempting large payments.
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let invoice = "lnbc1000n1..." // From recipient
    ///     let result = try await walletManager.payInvoice(invoice)
    ///     
    ///     print("Payment successful!")
    ///     print("Preimage: \(result.preimage)")
    ///     
    ///     if let fees = result.feesPaid {
    ///         print("Fees: \(fees) millisats")
    ///     }
    /// } catch let error as NWCError {
    ///     switch error.code {
    ///     case .insufficientBalance:
    ///         print("Not enough funds")
    ///     case .paymentFailed:
    ///         print("Payment failed: \(error.message)")
    ///     default:
    ///         print("Error: \(error.message)")
    ///     }
    /// }
    /// ```
    ///
    /// - Note: The payment process is atomic - either it completes fully or fails completely.
    public func payInvoice(_ invoice: String, amount: Int64? = nil) async throws -> PaymentResult {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.payInvoice) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support pay_invoice")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        // Create pay invoice request
        var params: [String: AnyCodable] = ["invoice": AnyCodable(invoice)]
        if let amount = amount {
            params["amount"] = AnyCodable(amount)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .payInvoice,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        // Send request and wait for response
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        // Decrypt and parse response
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let preimage = result["preimage"]?.value as? String else {
            throw NWCError(code: .other, message: "Invalid response format: missing preimage")
        }
        
        // Use helper for robust numeric parsing (JSON numbers can decode as various types)
        let feesPaid = extractInt64(from: result["fees_paid"])
        let paymentHash = result["payment_hash"]?.value as? String
        
        // Update last used timestamp
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx].lastUsedAt = Date()
            await saveConnections()
        }
        
        return PaymentResult(
            preimage: preimage,
            feesPaid: feesPaid,
            paymentHash: paymentHash
        )
    }
    
    /// Retrieves the current balance from the connected wallet.
    ///
    /// The balance is returned in millisatoshis (1/1000 of a satoshi).
    ///
    /// - Returns: The wallet balance in millisatoshis
    ///
    /// - Throws:
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support balance queries
    ///   - Network or parsing errors
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let balanceMillisats = try await walletManager.getBalance()
    ///     let balanceSats = balanceMillisats / 1000
    ///     print("Balance: \(balanceSats) sats")
    /// } catch {
    ///     print("Failed to get balance: \(error)")
    /// }
    /// ```
    ///
    /// - Note: The balance is also stored in the ``balance`` published property for observation.
    public func getBalance() async throws -> Int64 {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.getBalance) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support balance queries")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .getBalance,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let balance = extractInt64(from: result["balance"]) else {
            throw NWCError(code: .other, message: "Invalid response format: missing or invalid balance")
        }
        
        self.balance = balance
        return balance
    }
    
    /// Creates a Lightning invoice for receiving payments.
    ///
    /// Generates a BOLT11 invoice that others can pay to send funds to your wallet.
    ///
    /// - Parameters:
    ///   - amount: The amount to receive in millisatoshis
    ///   - description: Optional description/memo for the invoice
    ///   - expiry: Optional expiry time in seconds (default varies by wallet)
    ///
    /// - Returns: A BOLT11 invoice string that can be paid by others
    ///
    /// - Throws:
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support invoice creation
    ///   - Other wallet-specific errors
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     // Create invoice for 1000 sats
    ///     let invoice = try await walletManager.makeInvoice(
    ///         amount: 1_000_000, // 1000 sats in millisats
    ///         description: "Coffee payment",
    ///         expiry: 3600 // 1 hour
    ///     )
    ///     
    ///     // Display as QR code or share
    ///     showQRCode(for: invoice)
    /// } catch {
    ///     print("Failed to create invoice: \(error)")
    /// }
    /// ```
    public func makeInvoice(amount: Int64, description: String? = nil, expiry: Int? = nil) async throws -> String {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.makeInvoice) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support invoice creation")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        var params: [String: AnyCodable] = ["amount": AnyCodable(amount)]
        if let description = description {
            params["description"] = AnyCodable(description)
        }
        if let expiry = expiry {
            params["expiry"] = AnyCodable(expiry)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .makeInvoice,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let invoice = result["invoice"]?.value as? String else {
            throw NWCError(code: .other, message: "Invalid response format")
        }
        
        return invoice
    }
    
    /// Retrieves transaction history from the connected wallet.
    ///
    /// Fetches a list of recent transactions within the specified time range.
    ///
    /// - Parameters:
    ///   - from: Optional start date for the transaction range
    ///   - until: Optional end date for the transaction range
    ///   - limit: Maximum number of transactions to return
    ///
    /// - Returns: An array of ``NWCTransaction`` objects representing the transaction history
    ///
    /// - Throws:
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support transaction listing
    ///   - Network or parsing errors
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     // Get last 7 days of transactions
    ///     let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    ///     let transactions = try await walletManager.listTransactions(
    ///         from: weekAgo,
    ///         limit: 50
    ///     )
    ///     
    ///     for tx in transactions {
    ///         print("\(tx.type): \(tx.amount) millisats")
    ///     }
    /// } catch {
    ///     print("Failed to load transactions: \(error)")
    /// }
    /// ```
    ///
    /// - Note: The transactions are also stored in ``recentTransactions`` for observation.
    public func listTransactions(from: Date? = nil, until: Date? = nil, limit: Int? = nil) async throws -> [NWCTransaction] {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.listTransactions) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support transaction listing")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        var params: [String: AnyCodable] = [:]
        if let from = from {
            params["from"] = AnyCodable(Int64(from.timeIntervalSince1970))
        }
        if let until = until {
            params["until"] = AnyCodable(Int64(until.timeIntervalSince1970))
        }
        if let limit = limit {
            params["limit"] = AnyCodable(limit)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .listTransactions,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let transactionsData = result["transactions"]?.value as? [[String: Any]] else {
            throw NWCError(code: .other, message: "Invalid response format")
        }
        
        // Parse transactions
        let transactions = try transactionsData.compactMap { txData -> NWCTransaction? in
            let jsonData = try JSONSerialization.data(withJSONObject: txData)
            return try JSONDecoder().decode(NWCTransaction.self, from: jsonData)
        }
        
        self.recentTransactions = transactions
        return transactions
    }
    
    // MARK: - Keysend Operations
    
    /// A TLV record for keysend payments.
    ///
    /// TLV (Type-Length-Value) records allow attaching custom data to Lightning payments.
    public struct TLVRecord: Sendable {
        /// The TLV type identifier.
        public let type: UInt64
        
        /// The hex-encoded value.
        public let value: String
        
        /// Creates a new TLV record.
        ///
        /// - Parameters:
        ///   - type: The TLV type identifier
        ///   - value: The hex-encoded value
        public init(type: UInt64, value: String) {
            self.type = type
            self.value = value
        }
    }
    
    /// Sends a keysend payment directly to a Lightning node.
    ///
    /// Keysend payments don't require an invoice - they are sent directly to a node's
    /// public key. This is useful for spontaneous payments or tips.
    ///
    /// - Parameters:
    ///   - amount: The amount to send in millisatoshis
    ///   - pubkey: The recipient node's public key (33-byte compressed, hex-encoded)
    ///   - preimage: Optional custom preimage (32-byte hex). If not provided, the wallet generates one.
    ///   - tlvRecords: Optional TLV records to attach to the payment
    ///
    /// - Returns: A ``PaymentResult`` containing the payment preimage and optional fee information.
    ///
    /// - Throws:
    ///   - ``NWCError/insufficientBalance``: The wallet doesn't have enough funds
    ///   - ``NWCError/paymentFailed``: The payment could not be completed
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///   - ``NWCError/notImplemented``: Wallet doesn't support keysend
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     // Send 1000 sats to a node
    ///     let result = try await walletManager.payKeysend(
    ///         amount: 1_000_000,  // 1000 sats in millisats
    ///         pubkey: "03...node_pubkey..."
    ///     )
    ///     print("Keysend successful! Preimage: \(result.preimage)")
    /// } catch {
    ///     print("Keysend failed: \(error)")
    /// }
    /// ```
    public func payKeysend(
        amount: Int64,
        pubkey: String,
        preimage: String? = nil,
        tlvRecords: [TLVRecord]? = nil
    ) async throws -> PaymentResult {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.payKeysend) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support pay_keysend")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        var params: [String: AnyCodable] = [
            "amount": AnyCodable(amount),
            "pubkey": AnyCodable(pubkey)
        ]
        
        if let preimage = preimage {
            params["preimage"] = AnyCodable(preimage)
        }
        
        if let tlvRecords = tlvRecords, !tlvRecords.isEmpty {
            let tlvArray: [[String: Any]] = tlvRecords.map { record in
                ["type": Int64(record.type), "value": record.value]
            }
            params["tlv_records"] = AnyCodable(tlvArray)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .payKeysend,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result,
              let resultPreimage = result["preimage"]?.value as? String else {
            throw NWCError(code: .other, message: "Invalid response format: missing preimage")
        }
        
        let feesPaid = extractInt64(from: result["fees_paid"])
        
        // Update last used timestamp
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx].lastUsedAt = Date()
            await saveConnections()
        }
        
        return PaymentResult(
            preimage: resultPreimage,
            feesPaid: feesPaid,
            paymentHash: nil
        )
    }
    
    // MARK: - Invoice Lookup
    
    /// The result of looking up an invoice.
    public struct InvoiceLookupResult: Sendable {
        /// The transaction type (incoming for invoices, outgoing for payments).
        public let type: NWCTransactionType
        
        /// The current state of the invoice/payment.
        public let state: NWCTransactionState?
        
        /// The BOLT11 invoice string.
        public let invoice: String?
        
        /// Invoice description.
        public let description: String?
        
        /// Invoice description hash (for large descriptions).
        public let descriptionHash: String?
        
        /// Payment preimage (available if settled).
        public let preimage: String?
        
        /// Payment hash identifying this invoice/payment.
        public let paymentHash: String
        
        /// Amount in millisatoshis.
        public let amount: Int64
        
        /// Fees paid in millisatoshis (for outgoing payments).
        public let feesPaid: Int64?
        
        /// When the invoice was created.
        public let createdAt: Date
        
        /// When the invoice expires.
        public let expiresAt: Date?
        
        /// When the invoice was settled.
        public let settledAt: Date?
    }
    
    /// Looks up an invoice or payment by its payment hash.
    ///
    /// Use this to check the status of an invoice you created or a payment you made.
    ///
    /// - Parameter paymentHash: The payment hash (hex-encoded)
    ///
    /// - Returns: An ``InvoiceLookupResult`` with the invoice details
    ///
    /// - Throws:
    ///   - ``NWCError/notFound``: No invoice found with this payment hash
    ///   - ``NWCError/notImplemented``: Wallet doesn't support invoice lookup
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let result = try await walletManager.lookupInvoice(
    ///         paymentHash: "abc123..."
    ///     )
    ///     
    ///     switch result.state {
    ///     case .settled:
    ///         print("Invoice was paid!")
    ///     case .pending:
    ///         print("Still waiting for payment...")
    ///     case .expired:
    ///         print("Invoice expired")
    ///     default:
    ///         break
    ///     }
    /// } catch let error as NWCError where error.code == .notFound {
    ///     print("Invoice not found")
    /// }
    /// ```
    public func lookupInvoice(paymentHash: String) async throws -> InvoiceLookupResult {
        try await lookupInvoiceInternal(paymentHash: paymentHash, invoice: nil)
    }
    
    /// Looks up an invoice by its BOLT11 string.
    ///
    /// - Parameter invoice: The BOLT11 invoice string
    ///
    /// - Returns: An ``InvoiceLookupResult`` with the invoice details
    ///
    /// - Throws:
    ///   - ``NWCError/notFound``: Invoice not found
    ///   - ``NWCError/notImplemented``: Wallet doesn't support invoice lookup
    ///   - ``NWCError/unauthorized``: No active wallet connection
    public func lookupInvoice(invoice: String) async throws -> InvoiceLookupResult {
        try await lookupInvoiceInternal(paymentHash: nil, invoice: invoice)
    }
    
    private func lookupInvoiceInternal(paymentHash: String?, invoice: String?) async throws -> InvoiceLookupResult {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.lookupInvoice) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support lookup_invoice")
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        var params: [String: AnyCodable] = [:]
        if let paymentHash = paymentHash {
            params["payment_hash"] = AnyCodable(paymentHash)
        }
        if let invoice = invoice {
            params["invoice"] = AnyCodable(invoice)
        }
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .lookupInvoice,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        let response = try await sendRequestAndWaitForResponse(requestEvent)
        
        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result else {
            throw NWCError(code: .other, message: "Invalid response format: missing result")
        }
        
        // Parse the result
        guard let typeString = result["type"]?.value as? String,
              let type = NWCTransactionType(rawValue: typeString),
              let resultPaymentHash = result["payment_hash"]?.value as? String,
              let amount = extractInt64(from: result["amount"]) else {
            throw NWCError(code: .other, message: "Invalid response format: missing required fields")
        }
        
        let state: NWCTransactionState?
        if let stateString = result["state"]?.value as? String {
            state = NWCTransactionState(rawValue: stateString)
        } else {
            state = nil
        }
        
        let createdAt: Date
        if let timestamp = extractInt64(from: result["created_at"]) {
            createdAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            createdAt = Date()
        }
        
        let expiresAt: Date?
        if let timestamp = extractInt64(from: result["expires_at"]) {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            expiresAt = nil
        }
        
        let settledAt: Date?
        if let timestamp = extractInt64(from: result["settled_at"]) {
            settledAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            settledAt = nil
        }
        
        return InvoiceLookupResult(
            type: type,
            state: state,
            invoice: result["invoice"]?.value as? String,
            description: result["description"]?.value as? String,
            descriptionHash: result["description_hash"]?.value as? String,
            preimage: result["preimage"]?.value as? String,
            paymentHash: resultPaymentHash,
            amount: amount,
            feesPaid: extractInt64(from: result["fees_paid"]),
            createdAt: createdAt,
            expiresAt: expiresAt,
            settledAt: settledAt
        )
    }
    
    // MARK: - Wallet Info
    
    /// Information about the connected wallet/node.
    public struct WalletInfo: Sendable {
        /// Node alias/name.
        public let alias: String?
        
        /// Node color (hex string).
        public let color: String?
        
        /// Node public key.
        public let pubkey: String?
        
        /// Network the node is running on (mainnet, testnet, signet, regtest).
        public let network: String?
        
        /// Current block height.
        public let blockHeight: Int?
        
        /// Current block hash.
        public let blockHash: String?
        
        /// Supported NWC methods for this connection.
        public let methods: [NWCMethod]
        
        /// Supported notification types.
        public let notifications: [NWCNotificationType]

        /// Wallet app/connection name from metadata (e.g. "My Alby Hub").
        public let metadataName: String?

        /// The best display name available: metadata name, then alias, then nil.
        public var displayName: String? {
            metadataName ?? alias
        }
    }
    
    /// Retrieves information about the connected wallet/node.
    ///
    /// This provides details about the Lightning node including its alias, network,
    /// current block height, and supported capabilities.
    ///
    /// - Returns: A ``WalletInfo`` containing node details
    ///
    /// - Throws:
    ///   - ``NWCError/notImplemented``: Wallet doesn't support get_info
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///
    /// ## Example
    ///
    /// ```swift
    /// do {
    ///     let info = try await walletManager.getInfo()
    ///     
    ///     if let alias = info.alias {
    ///         print("Connected to: \(alias)")
    ///     }
    ///     
    ///     if let network = info.network {
    ///         print("Network: \(network)")
    ///     }
    ///     
    ///     print("Supported methods: \(info.methods.map { $0.rawValue })")
    /// } catch {
    ///     print("Failed to get wallet info: \(error)")
    /// }
    /// ```
    public func getInfo() async throws -> WalletInfo {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.getInfo) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support get_info")
        }
        try enforceRateLimit()

        isLoading = true
        defer { isLoading = false }

        let requestEvent = try NostrEvent.nwcRequest(
            method: .getInfo,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )

        let response = try await sendRequestAndWaitForResponse(requestEvent)

        let decryptedContent = try response.decryptNWCContent(
            with: connection.uri.secret,
            peerPubkey: connection.uri.walletPubkey
        )

        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        if let error = responseData.error {
            throw error
        }
        
        guard let result = responseData.result else {
            throw NWCError(code: .other, message: "Invalid response format: missing result")
        }
        
        // Parse methods
        var methods: [NWCMethod] = []
        if let methodStrings = result["methods"]?.value as? [String] {
            methods = methodStrings.compactMap { NWCMethod(rawValue: $0) }
        } else if let methodStrings = result["methods"]?.value as? [Any] {
            methods = methodStrings.compactMap { 
                guard let str = $0 as? String else { return nil }
                return NWCMethod(rawValue: str)
            }
        }
        
        // Parse notifications
        var notifications: [NWCNotificationType] = []
        if let notifStrings = result["notifications"]?.value as? [String] {
            notifications = notifStrings.compactMap { NWCNotificationType(rawValue: $0) }
        } else if let notifStrings = result["notifications"]?.value as? [Any] {
            notifications = notifStrings.compactMap {
                guard let str = $0 as? String else { return nil }
                return NWCNotificationType(rawValue: str)
            }
        }
        
        // Parse block height
        var blockHeight: Int?
        if let height = result["block_height"]?.value as? Int {
            blockHeight = height
        } else if let height = extractInt64(from: result["block_height"]) {
            blockHeight = Int(height)
        }
        
        // Parse metadata name
        var metadataName: String?
        if let metadata = result["metadata"]?.value as? [String: Any] {
            metadataName = metadata["name"] as? String
        }

        return WalletInfo(
            alias: result["alias"]?.value as? String,
            color: result["color"]?.value as? String,
            pubkey: result["pubkey"]?.value as? String,
            network: result["network"]?.value as? String,
            blockHeight: blockHeight,
            blockHash: result["block_hash"]?.value as? String,
            methods: methods,
            notifications: notifications,
            metadataName: metadataName
        )
    }
    
    // MARK: - Batch Payment Operations
    
    /// An individual invoice in a multi-pay batch.
    public struct BatchInvoice: Sendable {
        /// Optional identifier for tracking this invoice in responses.
        public let id: String?
        
        /// The BOLT11 invoice to pay.
        public let invoice: String
        
        /// Optional amount override in millisatoshis (for zero-amount invoices).
        public let amount: Int64?
        
        /// Creates a batch invoice entry.
        ///
        /// - Parameters:
        ///   - id: Optional identifier for tracking
        ///   - invoice: BOLT11 invoice string
        ///   - amount: Optional amount override in millisats
        public init(id: String? = nil, invoice: String, amount: Int64? = nil) {
            self.id = id
            self.invoice = invoice
            self.amount = amount
        }
    }
    
    /// Result of a batch payment operation for a single invoice.
    public struct BatchPaymentResult: Sendable {
        /// The identifier used for this invoice (either provided id or payment hash).
        public let id: String
        
        /// The payment result if successful.
        public let result: PaymentResult?
        
        /// The error if payment failed.
        public let error: NWCError?
        
        /// Whether this individual payment succeeded.
        public var isSuccess: Bool { result != nil }
    }
    
    /// Pays multiple invoices in a single batch operation.
    ///
    /// This sends all invoices to the wallet in one request. The wallet processes
    /// them and returns individual responses for each. This is more efficient than
    /// calling `payInvoice` multiple times.
    ///
    /// - Parameter invoices: Array of invoices to pay
    ///
    /// - Returns: Array of ``BatchPaymentResult`` for each invoice
    ///
    /// - Throws:
    ///   - ``NWCError/notImplemented``: Wallet doesn't support multi_pay_invoice
    ///   - ``NWCError/unauthorized``: No active wallet connection
    ///
    /// - Note: Individual payments may fail while others succeed. Check each result.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let invoices = [
    ///     BatchInvoice(id: "tip1", invoice: "lnbc1000n1..."),
    ///     BatchInvoice(id: "tip2", invoice: "lnbc2000n1..."),
    ///     BatchInvoice(id: "tip3", invoice: "lnbc3000n1...")
    /// ]
    ///
    /// let results = try await walletManager.multiPayInvoice(invoices)
    ///
    /// for result in results {
    ///     if result.isSuccess {
    ///         print("\(result.id): Paid successfully")
    ///     } else if let error = result.error {
    ///         print("\(result.id): Failed - \(error.message)")
    ///     }
    /// }
    /// ```
    public func multiPayInvoice(_ invoices: [BatchInvoice]) async throws -> [BatchPaymentResult] {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.multiPayInvoice) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support multi_pay_invoice")
        }
        guard !invoices.isEmpty else {
            return []
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        // Build invoices array
        let invoicesParams: [[String: Any]] = invoices.map { inv in
            var dict: [String: Any] = ["invoice": inv.invoice]
            if let id = inv.id {
                dict["id"] = id
            }
            if let amount = inv.amount {
                dict["amount"] = amount
            }
            return dict
        }

        let params: [String: AnyCodable] = ["invoices": AnyCodable(invoicesParams)]
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .multiPayInvoice,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        // For multi_pay, we need to collect multiple response events
        // Each response has a 'd' tag with the invoice id
        return try await collectMultiPayResponses(
            request: requestEvent,
            expectedCount: invoices.count,
            connection: connection
        )
    }
    
    /// An individual keysend in a multi-pay batch.
    public struct BatchKeysend: Sendable {
        /// Optional identifier for tracking this keysend in responses.
        public let id: String?
        
        /// The recipient node's public key.
        public let pubkey: String
        
        /// Amount to send in millisatoshis.
        public let amount: Int64
        
        /// Optional custom preimage.
        public let preimage: String?
        
        /// Optional TLV records.
        public let tlvRecords: [TLVRecord]?
        
        /// Creates a batch keysend entry.
        public init(
            id: String? = nil,
            pubkey: String,
            amount: Int64,
            preimage: String? = nil,
            tlvRecords: [TLVRecord]? = nil
        ) {
            self.id = id
            self.pubkey = pubkey
            self.amount = amount
            self.preimage = preimage
            self.tlvRecords = tlvRecords
        }
    }
    
    /// Sends multiple keysend payments in a single batch operation.
    ///
    /// - Parameter keysends: Array of keysend payments to make
    ///
    /// - Returns: Array of ``BatchPaymentResult`` for each keysend
    ///
    /// - Throws:
    ///   - ``NWCError/notImplemented``: Wallet doesn't support multi_pay_keysend
    ///   - ``NWCError/unauthorized``: No active wallet connection
    public func multiPayKeysend(_ keysends: [BatchKeysend]) async throws -> [BatchPaymentResult] {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }
        guard supportsMethod(.multiPayKeysend) else {
            throw NWCError(code: .notImplemented, message: "Wallet does not support multi_pay_keysend")
        }
        guard !keysends.isEmpty else {
            return []
        }
        try enforceRateLimit()
        
        isLoading = true
        defer { isLoading = false }
        
        // Build keysends array
        let keysendsParams: [[String: Any]] = keysends.map { ks in
            var dict: [String: Any] = [
                "pubkey": ks.pubkey,
                "amount": ks.amount
            ]
            if let id = ks.id {
                dict["id"] = id
            }
            if let preimage = ks.preimage {
                dict["preimage"] = preimage
            }
            if let tlvRecords = ks.tlvRecords, !tlvRecords.isEmpty {
                let tlvArray: [[String: Any]] = tlvRecords.map { record in
                    ["type": Int64(record.type), "value": record.value]
                }
                dict["tlv_records"] = tlvArray
            }
            return dict
        }

        let params: [String: AnyCodable] = ["keysends": AnyCodable(keysendsParams)]
        
        let requestEvent = try NostrEvent.nwcRequest(
            method: .multiPayKeysend,
            params: params,
            walletPubkey: connection.uri.walletPubkey,
            clientSecret: connection.uri.secret,
            encryption: try resolveEncryption()
        )
        
        return try await collectMultiPayResponses(
            request: requestEvent,
            expectedCount: keysends.count,
            connection: connection
        )
    }
    
    /// Collects multiple response events for batch payment operations.
    private func collectMultiPayResponses(
        request: NostrEvent,
        expectedCount: Int,
        connection: WalletConnection
    ) async throws -> [BatchPaymentResult] {
        // Subscribe to responses
        let filter = Filter(
            authors: [connection.uri.walletPubkey],
            kinds: [EventKind.nwcResponse.rawValue],
            e: [request.id]
        )
        
        let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
        subscriptions[request.id] = subscription.id
        
        // Publish request
        let publishResults = await relayPool.publish(request)
        guard publishResults.contains(where: { $0.success }) else {
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw NWCError(code: .other, message: "Failed to publish request to any relay")
        }
        
        // Collect responses with timeout
        var results: [BatchPaymentResult] = []
        let walletPubkey = connection.uri.walletPubkey
        let secret = connection.uri.secret
        
        do {
            try await withThrowingTaskGroup(of: [BatchPaymentResult].self) { group in
                // Response collection task
                group.addTask {
                    var collected: [BatchPaymentResult] = []
                    for await event in subscription.events {
                        guard event.pubkey == walletPubkey else { continue }
                        guard event.kind == EventKind.nwcResponse.rawValue else { continue }
                        
                        // Parse this response
                        if let result = try? await self.parseMultiPayResponse(event, secret: secret, walletPubkey: walletPubkey) {
                            collected.append(result)
                            if collected.count >= expectedCount {
                                break
                            }
                        }
                    }
                    return collected
                }
                
                // Timeout task (60 seconds for batch operations)
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return []
                }
                
                if let first = try await group.next(), !first.isEmpty {
                    results = first
                    group.cancelAll()
                }
            }
        } catch {
            // Timeout or cancellation - return what we have
        }
        
        await relayPool.closeSubscription(id: subscription.id)
        subscriptions.removeValue(forKey: request.id)
        
        return results
    }
    
    private func parseMultiPayResponse(
        _ event: NostrEvent,
        secret: String,
        walletPubkey: String
    ) async throws -> BatchPaymentResult {
        let decryptedContent = try event.decryptNWCContent(
            with: secret,
            peerPubkey: walletPubkey
        )
        
        let responseData = try JSONDecoder().decode(NWCResponse.self, from: Data(decryptedContent.utf8))
        
        // Get the 'd' tag for the id
        let dTag = event.tags.first { $0.count >= 2 && $0[0] == "d" }
        let id = dTag?[1] ?? "unknown"
        
        if let error = responseData.error {
            return BatchPaymentResult(id: id, result: nil, error: error)
        }
        
        guard let result = responseData.result,
              let preimage = result["preimage"]?.value as? String else {
            return BatchPaymentResult(
                id: id,
                result: nil,
                error: NWCError(code: .other, message: "Invalid response format")
            )
        }
        
        let paymentResult = PaymentResult(
            preimage: preimage,
            feesPaid: extractInt64(from: result["fees_paid"]),
            paymentHash: nil
        )
        
        return BatchPaymentResult(id: id, result: paymentResult, error: nil)
    }
    
    // MARK: - Private Methods
    
    /// Extracts an Int64 value from an AnyCodable, handling various numeric types.
    ///
    /// JSON numbers can be decoded as Int, Int64, Double, etc. depending on their size
    /// and the decoder. This helper handles all common cases.
    private func extractInt64(from anyCodable: AnyCodable?) -> Int64? {
        guard let value = anyCodable?.value else { return nil }
        
        if let int64 = value as? Int64 {
            return int64
        } else if let int = value as? Int {
            return Int64(int)
        } else if let double = value as? Double {
            return Int64(double)
        } else if let uint64 = value as? UInt64, uint64 <= UInt64(Int64.max) {
            return Int64(uint64)
        } else if let nsNumber = value as? NSNumber {
            return nsNumber.int64Value
        }
        
        return nil
    }
    
    private func enforceRateLimit() throws {
        guard rateLimiter.consume() else {
            throw NWCError(code: .rateLimited, message: "Too many wallet requests. Please wait.")
        }
    }
    
    private func resolveEncryption() throws -> NWCEncryption {
        guard let capabilities = activeConnection?.capabilities else {
            return .nip44
        }

        if capabilities.encryptionSchemes.contains(.nip44) {
            return .nip44
        }
        if capabilities.encryptionSchemes.contains(.nip04) {
            return .nip04
        }

        throw NWCError(code: .unsupportedEncryption, message: "Wallet does not support a compatible encryption scheme")
    }
    
    private func fetchWalletInfo(walletPubkey: String) async throws -> NWCInfo? {
        // Create filter for info event
        let filter = Filter(
            authors: [walletPubkey],
            kinds: [EventKind.nwcInfo.rawValue],
            limit: 1
        )

        // Subscribe and collect info event
        let subscription = try await relayPool.walletSubscribe(
            filters: [filter],
            id: "nwc-info-\(UUID().uuidString)"
        )

        var infoEvent: NostrEvent?

        // Use TaskGroup for proper timeout handling - when one task completes, cancel the other
        do {
            infoEvent = try await withThrowingTaskGroup(of: NostrEvent?.self) { group in
                // Task 1: Listen for info events
                group.addTask {
                    for await event in subscription.events {
                        // Return the first matching event
                        return event
                    }
                    // Stream ended without finding an event
                    return nil
                }

                // Task 2: Timeout after 5 seconds
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return nil
                }

                // Wait for the first task to complete and cancel the other
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }

                return nil
            }
        } catch {
            // Timeout or cancellation - no info event found
            infoEvent = nil
        }

        await relayPool.closeSubscription(id: subscription.id)

        guard let event = infoEvent else {
            return nil
        }

        return NWCInfo(content: event.content, tags: event.tags)
    }
    
    /// Timeout duration for NWC requests (30 seconds)
    private static let requestTimeoutNanoseconds: UInt64 = 30_000_000_000
    
    private func sendRequestAndWaitForResponse(_ request: NostrEvent) async throws -> NostrEvent {
        guard let connection = activeConnection else {
            throw NWCError(code: .unauthorized, message: "No active wallet connection")
        }

        // Prepare subscription first to avoid missing early responses
        let filter = Filter(
            authors: [connection.uri.walletPubkey],
            kinds: [EventKind.nwcResponse.rawValue],
            e: [request.id]
        )

        let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
        subscriptions[request.id] = subscription.id

        // Publish request
        let publishResults = await relayPool.publish(request)

        // Check if at least one relay accepted the event
        guard publishResults.contains(where: { $0.success }) else {
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw NWCError(code: .other, message: "Failed to publish request to any relay")
        }

        // Capture values needed by the task to avoid actor isolation issues
        let walletPubkey = connection.uri.walletPubkey
        let requestId = request.id
        
        // Wait for response with timeout using TaskGroup for proper cancellation
        // This ensures that when one task completes (either timeout or response),
        // the other is automatically cancelled, preventing race conditions.
        do {
            let result = try await withThrowingTaskGroup(of: NostrEvent?.self) { group in
                // Task 1: Listen for response events
                group.addTask {
                    for await event in subscription.events {
                        // Verify event is from the wallet
                        guard event.pubkey == walletPubkey else { continue }
                        // Verify correct event kind
                        guard event.kind == EventKind.nwcResponse.rawValue else { continue }
                        // Verify this is a response to our request (via 'e' tag)
                        guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == requestId }) else {
                            continue
                        }
                        return event
                    }
                    // Stream ended without finding a matching event
                    return nil
                }
                
                // Task 2: Timeout after 30 seconds
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.requestTimeoutNanoseconds)
                    return nil // Signal timeout by returning nil
                }
                
                // Wait for the first task to complete
                // When one completes, cancel the other
                if let result = try await group.next() {
                    // Cancel remaining tasks (timeout or listener)
                    group.cancelAll()
                    
                    if let event = result {
                        return event
                    } else {
                        // nil means either timeout or stream ended without match
                        throw RelayError.timeout
                    }
                }
                
                // Should not reach here, but handle gracefully
                throw RelayError.timeout
            }
            
            // Check if we already processed this response (prevents duplicate handling)
            guard !processedResponses.contains(result.id) else {
                throw NWCError(code: .other, message: "Duplicate response received")
            }
            
            // Mark response as processed and clean up
            processedResponses.insert(result.id)
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            
            return result
            
        } catch is CancellationError {
            // Clean up on cancellation
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw NWCError(code: .other, message: "Request was cancelled")
        } catch {
            // Clean up on any error
            await relayPool.closeSubscription(id: subscription.id)
            subscriptions.removeValue(forKey: request.id)
            throw error
        }
    }
    
    private func subscribeToNotifications() async {
        // Cancel any existing notification task first
        notificationTask?.cancel()
        notificationTask = nil
        
        guard let connection = activeConnection else { return }
        
        // Check if wallet supports notifications
        guard let capabilities = connection.capabilities,
              !capabilities.notifications.isEmpty else {
            return
        }
        
        guard let clientPubkey = try? KeyPair(privateKey: connection.uri.secret).publicKey else {
            nwcLogger.error("Failed to derive client pubkey for notifications")
            return
        }
        let filter = Filter(
            authors: [connection.uri.walletPubkey],
            kinds: [EventKind.nwcNotification.rawValue, EventKind.nwcNotificationLegacy.rawValue],
            p: [clientPubkey]
        )
        
        do {
            let subscription = try await relayPool.walletSubscribe(filters: [filter], id: nil)
            notificationSubscription = subscription.id
            
            // Store task reference so we can cancel it on disconnect
            notificationTask = Task { [weak self] in
                for await event in subscription.events {
                    // Check for cancellation
                    guard !Task.isCancelled else { break }
                    await self?.handleNotification(event)
                }
            }
        } catch {
            nwcLogger.error("Failed to subscribe to notifications", error: error)
        }
    }
    
    private func handleNotification(_ event: NostrEvent) async {
        guard let connection = activeConnection else { return }
        
        guard !processedNotifications.contains(event.id) else { return }
        guard event.pubkey == connection.uri.walletPubkey else { return }
        processedNotifications.insert(event.id)
        
        do {
            let decryptedContent = try event.decryptNWCContent(
                with: connection.uri.secret,
                peerPubkey: connection.uri.walletPubkey
            )
            
            let notification = try JSONDecoder().decode(NWCNotification.self, from: Data(decryptedContent.utf8))
            
            // Handle different notification types
            switch notification.notificationType {
            case .paymentReceived:
                nwcLogger.info("Payment received notification", metadata: LogMetadata(["wallet": connection.uri.walletPubkey]))
                // Update balance
                _ = try? await getBalance()
                
            case .paymentSent:
                nwcLogger.info("Payment sent notification", metadata: LogMetadata(["wallet": connection.uri.walletPubkey]))
                // Update balance and transaction list
                _ = try? await getBalance()
                _ = try? await listTransactions(limit: 10)
            }
            
        } catch {
            nwcLogger.error("Failed to handle notification", error: error)
        }
    }
    
    // MARK: - Automatic Reconnection
    
    /// Enables or disables automatic reconnection.
    ///
    /// When enabled, the manager will automatically attempt to reconnect
    /// if the connection is lost due to network issues.
    ///
    /// - Parameter enabled: Whether to enable auto-reconnection
    public func setAutoReconnect(enabled: Bool) {
        isAutoReconnectEnabled = enabled
        if !enabled {
            cancelReconnection()
        }
    }
    
    /// Cancels any pending reconnection attempts.
    public func cancelReconnection() {
        reconnectionTask?.cancel()
        reconnectionTask = nil
        reconnectionAttempts = 0
    }
    
    /// Schedules an automatic reconnection attempt with exponential backoff.
    ///
    /// This is called internally when connection failures are detected.
    private func scheduleReconnection() {
        guard isAutoReconnectEnabled else { return }
        guard activeConnection != nil else { return }
        guard reconnectionAttempts < Self.maxReconnectionAttempts else {
            nwcLogger.error("Maximum reconnection attempts reached", metadata: LogMetadata([
                "attempts": String(reconnectionAttempts)
            ]))
            connectionState = .failed(NWCError(code: .other, message: "Connection failed after \(reconnectionAttempts) attempts"))
            return
        }
        
        // Cancel any existing reconnection task
        reconnectionTask?.cancel()
        
        // Calculate delay with exponential backoff and jitter
        let baseDelay = Self.baseReconnectionDelay * pow(2.0, Double(reconnectionAttempts))
        let jitter = Double.random(in: 0...0.3) * baseDelay
        let delay = min(baseDelay + jitter, Self.maxReconnectionDelay)
        
        nwcLogger.info("Scheduling reconnection", metadata: LogMetadata([
            "attempt": String(reconnectionAttempts + 1),
            "delay_seconds": String(format: "%.1f", delay)
        ]))
        
        reconnectionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                
                self.reconnectionAttempts += 1
                
                do {
                    try await self.reconnect()
                    // Success - reset attempts
                    self.reconnectionAttempts = 0
                    nwcLogger.info("Reconnection successful")
                } catch {
                    nwcLogger.warning("Reconnection attempt failed: \(error.localizedDescription)", metadata: LogMetadata([
                        "attempt": String(self.reconnectionAttempts)
                    ]))
                    // Schedule next attempt
                    self.scheduleReconnection()
                }
            } catch {
                // Task was cancelled or sleep failed
            }
        }
    }
    
    /// Handles connection state changes and triggers reconnection if needed.
    ///
    /// Call this when detecting connection loss (e.g., WebSocket disconnect).
    public func handleConnectionLost() {
        guard case .connected = connectionState else { return }
        
        connectionState = .disconnected
        nwcLogger.warning("Connection lost, attempting to reconnect")
        
        scheduleReconnection()
    }
    
    // MARK: - Persistence
    
    private func loadConnections() async {
        do {
            let data = try await keychain.load(key: Self.connectionsKey)
            let loadedConnections = try JSONDecoder().decode([WalletConnection].self, from: data)

            // Merge loaded connections with any that were added during connect()
            // This handles the race condition where connect() runs before loadConnections()
            for loaded in loadedConnections {
                if !connections.contains(where: { $0.id == loaded.id }) {
                    connections.append(loaded)
                }
            }

            // Only load active connection if one isn't already set (connect() might have set it)
            if activeConnection == nil,
               let activeData = try? await keychain.load(key: Self.activeConnectionKey),
               let activeId = String(data: activeData, encoding: .utf8) {
                activeConnection = connections.first { $0.id == activeId }
            }
        } catch {
            // No saved connections - keep any that were added during connect()
        }
    }
    
    private func saveConnections() async {
        do {
            let data = try JSONEncoder().encode(connections)
            try await keychain.store(data, forKey: Self.connectionsKey)
        } catch {
            nwcLogger.error("Failed to save connections", error: error)
        }
    }
    
    private func saveActiveConnection() async {
        do {
            if let activeId = activeConnection?.id,
               let data = activeId.data(using: .utf8) {
                try await keychain.store(data, forKey: Self.activeConnectionKey)
            } else {
                try await keychain.remove(key: Self.activeConnectionKey)
            }
        } catch {
            nwcLogger.error("Failed to save active connection", error: error)
        }
    }
}

// MARK: - Convenience Extensions

extension WalletConnectManager {
    
    /// Checks if the active wallet supports a specific NWC method.
    ///
    /// Use this to conditionally enable features based on wallet capabilities.
    ///
    /// - Parameter method: The NWC method to check support for
    /// - Returns: `true` if the wallet supports the method, `false` otherwise
    ///
    /// ## Example
    ///
    /// ```swift
    /// if walletManager.supportsMethod(.payInvoice) {
    ///     // Show payment UI
    /// } else {
    ///     // Show "not supported" message
    /// }
    /// ```
    public func supportsMethod(_ method: NWCMethod) -> Bool {
        guard let capabilities = activeConnection?.capabilities else {
            // When capabilities are unknown (info event wasn't received), optimistically
            // assume the wallet supports the method. The wallet will return an appropriate
            // error if it doesn't, which is better than silently blocking all operations.
            return true
        }
        return capabilities.methods.contains(method)
    }
    
    /// Indicates whether the active wallet supports real-time notifications.
    ///
    /// When `true`, the wallet will send notifications for incoming and outgoing payments.
    public var supportsNotifications: Bool {
        guard let capabilities = activeConnection?.capabilities else {
            return false
        }
        return !capabilities.notifications.isEmpty
    }
    
    /// The preferred encryption scheme for the active wallet connection.
    ///
    /// Returns NIP-44 if supported (the secure default), otherwise falls back to NIP-04
    /// for legacy wallet compatibility.
    ///
    /// - Note: NIP-44 is the recommended encryption scheme. NIP-04 is deprecated and
    ///   should only be used for backwards compatibility with older wallets.
    public var preferredEncryption: NWCEncryption {
        guard let capabilities = activeConnection?.capabilities else {
            // Default to NIP-44 (secure) when capabilities are unknown
            // The wallet will respond with an error if it doesn't support NIP-44
            return .nip44
        }
        
        // Prefer NIP-44 if supported, fall back to NIP-04 only if explicitly needed
        if capabilities.encryptionSchemes.contains(.nip44) {
            return .nip44
        } else if capabilities.encryptionSchemes.contains(.nip04) {
            return .nip04
        } else {
            // No encryption schemes specified, assume NIP-44 support
            return .nip44
        }
    }
}
