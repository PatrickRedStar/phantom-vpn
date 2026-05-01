// AdminHttpClient — URLSession client for the phantom-server admin API
// (mTLS to https://<tunnel-gateway>:8080 over the VPN tunnel).
//
// ═══════════════════════════════════════════════════════════════════════
// Ed25519 client-certificate limitation on iOS
// ═══════════════════════════════════════════════════════════════════════
// Apple's URLSession + SecIdentity stack does not reliably accept Ed25519
// client identities. If the admin API mTLS handshake fails on iOS, the
// workaround is to regenerate the admin client cert as ECDSA P-256 via
// `phantom-keygen` (Ed25519 is the default; switch to `--key-type ecdsa`).
//
// The VPN tunnel itself is unaffected: the Rust `client-apple` crate uses
// rustls + ring, which handle Ed25519 natively during data-plane TLS.
// Only the URLSession-based admin API is affected.
// ═══════════════════════════════════════════════════════════════════════

import Foundation
import NetworkExtension
import PhantomKit
import Security
import CryptoKit
import os.log

// MARK: - Models

/// `/api/status` response.
public struct AdminStatus: Codable {
    public let uptimeSecs: Int64
    public let activeSessions: Int
    public let serverIp: String?
    public let serverAddr: String?
    public let exitIp: String?

    private enum CodingKeys: String, CodingKey {
        case uptimeSecs = "uptime_secs"
        case activeSessions = "active_sessions"
        case sessionsActive = "sessions_active"
        case serverIp = "server_ip"
        case serverAddr = "server_addr"
        case exitIp = "exit_ip"
    }

    public init(
        uptimeSecs: Int64,
        activeSessions: Int,
        serverIp: String? = nil,
        serverAddr: String? = nil,
        exitIp: String? = nil
    ) {
        self.uptimeSecs = uptimeSecs
        self.activeSessions = activeSessions
        self.serverIp = serverIp
        self.serverAddr = serverAddr
        self.exitIp = exitIp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uptimeSecs = try c.decode(Int64.self, forKey: .uptimeSecs)
        activeSessions = try c.decodeIfPresent(Int.self, forKey: .activeSessions)
            ?? c.decodeIfPresent(Int.self, forKey: .sessionsActive)
            ?? 0
        serverIp = try c.decodeIfPresent(String.self, forKey: .serverIp)
            ?? c.decodeIfPresent(String.self, forKey: .exitIp)
        serverAddr = try c.decodeIfPresent(String.self, forKey: .serverAddr)
        exitIp = try c.decodeIfPresent(String.self, forKey: .exitIp)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uptimeSecs, forKey: .uptimeSecs)
        try c.encode(activeSessions, forKey: .sessionsActive)
        try c.encodeIfPresent(serverIp, forKey: .serverIp)
        try c.encodeIfPresent(serverAddr, forKey: .serverAddr)
        try c.encodeIfPresent(exitIp, forKey: .exitIp)
    }
}

/// `/api/me` response.
public struct AdminSelfInfo: Codable {
    public let name: String
    public let isAdmin: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case isAdmin = "is_admin"
    }
}

/// Entry in `/api/clients`.
public struct AdminClient: Codable, Identifiable {
    public let name: String
    public let fingerprint: String
    public let tunAddr: String
    public let enabled: Bool
    public let connected: Bool
    public let bytesRx: Int64
    public let bytesTx: Int64
    public let createdAt: String
    public let lastSeenSecs: Int64?
    public let expiresAt: Int64?
    public let isAdmin: Bool

    public var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, fingerprint, enabled, connected
        case tunAddr = "tun_addr"
        case bytesRx = "bytes_rx"
        case bytesTx = "bytes_tx"
        case createdAt = "created_at"
        case lastSeenSecs = "last_seen_secs"
        case expiresAt = "expires_at"
        case isAdmin = "is_admin"
    }
}

/// Entry in `/api/clients/:name/stats`.
public struct ClientStat: Codable {
    public let ts: Int64
    public let bytesRx: Int64
    public let bytesTx: Int64

    private enum CodingKeys: String, CodingKey {
        case ts
        case bytesRx = "bytes_rx"
        case bytesTx = "bytes_tx"
    }
}

/// Entry in `/api/clients/:name/logs`.
public struct ClientLog: Codable {
    public let ts: Int64
    public let dst: String
    public let port: Int
    public let proto: String
    public let bytes: Int64
}

// MARK: - Errors

/// Errors surfaced by `AdminHttpClient`.
public enum AdminHttpError: Error, LocalizedError {
    case badStatus(Int)
    case transport(Error)
    case decoding(Error)
    case identityCreation(String)
    case pinMismatch
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code):           return "HTTP \(code)"
        case .transport(let e):              return "Transport error: \(e.localizedDescription)"
        case .decoding(let e):               return "Decode error: \(e.localizedDescription)"
        case .identityCreation(let msg):     return "Failed to build client identity: \(msg)"
        case .pinMismatch:                   return "Server cert fingerprint mismatch"
        case .invalidResponse:               return "Invalid server response"
        }
    }
}

// MARK: - URLSession delegate

/// URLSession delegate that:
/// 1. Presents the client SecIdentity for mTLS challenges.
/// 2. Performs TOFU SHA-256 pinning on the server cert — accepts on first
///    handshake, rejects on mismatch thereafter.
final class MTLSDelegate: NSObject, URLSessionDelegate {

    private let clientIdentity: SecIdentity
    private let clientCertificates: [SecCertificate]
    private let pinnedServerCertFp: String?

    private let lock = NSLock()
    private var _lastServerCertFp: String?

    var lastServerCertFp: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastServerCertFp
    }

    init(identity: SecIdentity, certificates: [SecCertificate], pinnedFingerprint: String?) {
        self.clientIdentity = identity
        self.clientCertificates = certificates
        self.pinnedServerCertFp = pinnedFingerprint?.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            let cred = URLCredential(
                identity: clientIdentity,
                certificates: clientCertificates,
                persistence: .none
            )
            completionHandler(.useCredential, cred)

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            guard let leaf = leafCertificate(from: trust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            let der = SecCertificateCopyData(leaf) as Data
            let fp = sha256Hex(der)

            lock.lock()
            _lastServerCertFp = fp
            lock.unlock()

            if let pinned = pinnedServerCertFp {
                if fp == pinned {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            } else {
                // TOFU: accept first handshake, caller persists `lastServerCertFp`.
                completionHandler(.useCredential, URLCredential(trust: trust))
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        if #available(iOS 15.0, *) {
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            return chain?.first
        } else {
            return SecTrustGetCertificateAtIndex(trust, 0)
        }
    }
}

// MARK: - Client

/// URLSession-backed admin HTTP client with mTLS + TOFU cert pinning.
///
/// - Note: `baseURL` is typically `https://10.7.0.1:8080` or the gateway
///   derived from `VpnProfile.tunAddr` — routable only through the VPN tunnel.
///   No hostname verification is performed; trust is anchored on the TOFU
///   SHA-256 pin.
@MainActor
public final class AdminHttpClient {

    private let baseURL: URL
    private let session: URLSession
    private let delegate: MTLSDelegate

    /// Most recently observed server-cert fingerprint (hex, lowercase).
    /// Populated on every successful handshake — caller should persist it
    /// into `VpnProfile.cachedAdminServerCertFp` after first connect.
    public var lastServerCertFp: String? { delegate.lastServerCertFp }

    /// Builds a client. Fails if the PEMs can't be parsed into a SecIdentity.
    /// - Parameters:
    ///   - baseURL: Admin server URL, e.g. `https://10.7.0.1:8080`.
    ///   - clientCertPem: PEM-encoded client certificate chain.
    ///   - clientKeyPem: PEM-encoded client private key (PKCS8 or PKCS1).
    ///   - pinnedServerCertFp: Optional previously-pinned server-cert
    ///     SHA-256 (hex). `nil` → TOFU on next handshake.
    /// - Throws: `AdminHttpError.identityCreation` on PEM / Keychain errors.
    public init(
        baseURL: URL,
        clientCertPem: String,
        clientKeyPem: String,
        pinnedServerCertFp: String?
    ) throws {
        self.baseURL = baseURL
        let (identity, chain) = try Self.makeIdentity(certPem: clientCertPem, keyPem: clientKeyPem)
        self.delegate = MTLSDelegate(
            identity: identity,
            certificates: chain,
            pinnedFingerprint: pinnedServerCertFp
        )
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    // MARK: Endpoints

    /// `GET /api/status` — server uptime and active session count.
    public func getStatus() async throws -> AdminStatus {
        try await request("GET", "/api/status")
    }

    /// `GET /api/me` — current-client name and admin flag.
    public func getMe() async throws -> AdminSelfInfo {
        try await request("GET", "/api/me")
    }

    /// `GET /api/clients` — all registered clients.
    public func listClients() async throws -> [AdminClient] {
        try await request("GET", "/api/clients")
    }

    /// `POST /api/clients` — creates a new client. `expiresDays = 0` = perpetual.
    public func createClient(
        name: String,
        expiresDays: Int,
        isAdmin: Bool = false
    ) async throws -> AdminClient {
        let body = CreateClientBody(name: name, expiresDays: expiresDays, isAdmin: isAdmin)
        return try await request("POST", "/api/clients", body: body)
    }

    /// `POST /api/clients/:name/admin` — toggles the admin flag on a client.
    public func setAdmin(name: String, isAdmin: Bool) async throws {
        let body = SetAdminBody(isAdmin: isAdmin)
        try await requestVoid("POST", "/api/clients/\(escape(name))/admin", body: body)
    }

    /// `DELETE /api/clients/:name` — removes a client and its certificates.
    public func deleteClient(name: String) async throws {
        try await requestVoid("DELETE", "/api/clients/\(escape(name))")
    }

    /// `POST /api/clients/:name/enable`.
    public func enableClient(name: String) async throws {
        try await requestVoid("POST", "/api/clients/\(escape(name))/enable")
    }

    /// `POST /api/clients/:name/disable`.
    public func disableClient(name: String) async throws {
        try await requestVoid("POST", "/api/clients/\(escape(name))/disable")
    }

    /// `GET /api/clients/:name/conn_string` — returns the raw `ghs://…`
    /// connection string for `name`.
    public func getConnString(name: String) async throws -> String {
        let data = try await requestRaw("GET", "/api/clients/\(escape(name))/conn_string")
        guard let str = String(data: data, encoding: .utf8) else {
            throw AdminHttpError.invalidResponse
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `GET /api/clients/:name/stats` — historical traffic counters.
    public func getClientStats(name: String) async throws -> [ClientStat] {
        try await request("GET", "/api/clients/\(escape(name))/stats")
    }

    /// `GET /api/clients/:name/logs` — last 200 destination records.
    public func getClientLogs(name: String) async throws -> [ClientLog] {
        try await request("GET", "/api/clients/\(escape(name))/logs")
    }

    /// `POST /api/clients/:name/subscription` — extend/set/cancel/revoke.
    public func subscription(name: String, action: String, days: Int? = nil) async throws {
        let body = SubscriptionBody(action: action, days: days)
        try await requestVoid("POST", "/api/clients/\(escape(name))/subscription", body: body)
    }

    // MARK: - Private plumbing

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: Encodable? = nil
    ) async throws -> T {
        let data = try await requestRaw(method, path, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AdminHttpError.decoding(error)
        }
    }

    private func requestVoid(
        _ method: String,
        _ path: String,
        body: Encodable? = nil
    ) async throws {
        _ = try await requestRaw(method, path, body: body)
    }

    private func requestRaw(
        _ method: String,
        _ path: String,
        body: Encodable? = nil
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AdminHttpError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            req.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw AdminHttpError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AdminHttpError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AdminHttpError.badStatus(http.statusCode)
        }
        return data
    }

    private func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    // MARK: - Body DTOs

    private struct CreateClientBody: Encodable {
        let name: String
        let expiresDays: Int
        let isAdmin: Bool
        enum CodingKeys: String, CodingKey {
            case name
            case expiresDays = "expires_days"
            case isAdmin = "is_admin"
        }
    }
    private struct SetAdminBody: Encodable {
        let isAdmin: Bool
        enum CodingKeys: String, CodingKey { case isAdmin = "is_admin" }
    }
    private struct SubscriptionBody: Encodable {
        let action: String
        let days: Int?
    }
}

// MARK: - Identity construction

private extension AdminHttpClient {

    /// Parses a PEM cert chain + PKCS8 private key into a `SecIdentity`
    /// usable as an mTLS client credential.
    ///
    /// Strategy:
    /// 1. Parse each `-----BEGIN CERTIFICATE-----` block → `SecCertificate`.
    /// 2. Strip PEM markers from the private key, decode base64.
    /// 3. Detect key algorithm via PKCS8 OID prefix; Ed25519 is rejected
    ///    here with a clear error (see file-header note).
    /// 4. Build `SecKey` via `SecKeyCreateWithData` using RSA / ECDSA
    ///    parameters.
    /// 5. Pair the `SecCertificate` and `SecKey` into a `SecIdentity` via
    ///    a temporary Keychain add-and-query cycle.
    static func makeIdentity(
        certPem: String,
        keyPem: String
    ) throws -> (SecIdentity, [SecCertificate]) {
        let chain = parseCertificateChain(certPem)
        guard let leaf = chain.first else {
            throw AdminHttpError.identityCreation("No certificate in PEM")
        }

        let keyDer = try decodePemKey(keyPem)
        let keyMaterial = try inspectPkcs8(keyDer)

        var attrs: [CFString: Any] = [
            kSecAttrKeyType: keyMaterial.keyType,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        if let keySizeInBits = keyMaterial.keySizeInBits {
            attrs[kSecAttrKeySizeInBits] = keySizeInBits
        }
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyMaterial.keyData as CFData, attrs as CFDictionary, &error) else {
            let msg = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            _ = attrs.removeValue(forKey: kSecAttrKeyType)
            throw AdminHttpError.identityCreation("SecKeyCreateWithData failed: \(msg)")
        }

        let identity = try buildIdentityViaKeychain(certificate: leaf, privateKey: secKey)
        return (identity, chain)
    }

    static func parseCertificateChain(_ pem: String) -> [SecCertificate] {
        let pattern = "-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = pem as NSString
        let matches = regex.matches(in: pem, range: NSRange(location: 0, length: ns.length))
        var out: [SecCertificate] = []
        for m in matches {
            let b64 = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let der = Data(base64Encoded: b64) else { continue }
            if let cert = SecCertificateCreateWithData(nil, der as CFData) {
                out.append(cert)
            }
        }
        return out
    }

    static func decodePemKey(_ pem: String) throws -> Data {
        let stripped = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: stripped) else {
            throw AdminHttpError.identityCreation("Key PEM base64 decode failed")
        }
        return data
    }

    struct SecKeyMaterial {
        let keyType: CFString
        let keyData: Data
        let keySizeInBits: Int?
    }

    /// Inspects a PKCS8 blob and returns (SecKeyType, raw-key-bytes suitable
    /// for `SecKeyCreateWithData`). Rejects Ed25519 up-front.
    static func inspectPkcs8(_ der: Data) throws -> SecKeyMaterial {
        // PKCS8 AlgorithmIdentifier OIDs appear as byte sequences near the
        // start of the structure. We do a coarse substring search rather
        // than a full DER parse.
        //
        //   RSA:       1.2.840.113549.1.1.1  → 06 09 2A 86 48 86 F7 0D 01 01 01
        //   EC:        1.2.840.10045.2.1     → 06 07 2A 86 48 CE 3D 02 01
        //   P-256 OID: 1.2.840.10045.3.1.7   → 06 08 2A 86 48 CE 3D 03 01 07
        //   Ed25519:   1.3.101.112           → 06 03 2B 65 70
        let rsaOid: [UInt8]      = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let ecOid: [UInt8]       = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let ed25519Oid: [UInt8]  = [0x06, 0x03, 0x2B, 0x65, 0x70]

        let bytes = [UInt8](der)

        if containsSubsequence(bytes, ed25519Oid) {
            throw AdminHttpError.identityCreation(
                "Ed25519 client certs are not supported on iOS — regenerate as ECDSA P-256"
            )
        }
        if containsSubsequence(bytes, rsaOid) {
            return SecKeyMaterial(
                keyType: kSecAttrKeyTypeRSA,
                keyData: try unwrapPkcs8PrivateKey(der),
                keySizeInBits: nil
            )
        }
        if containsSubsequence(bytes, ecOid) {
            let sec1 = try unwrapPkcs8PrivateKey(der)
            return SecKeyMaterial(
                keyType: kSecAttrKeyTypeECSECPrimeRandom,
                keyData: try sec1EcPrivateKeyToSecKeyData(sec1),
                keySizeInBits: 256
            )
        }
        throw AdminHttpError.identityCreation("Unrecognised key algorithm in PKCS8 blob")
    }

    /// Security.framework imports EC private keys as the same external
    /// representation it exports: X9.63 public point followed by the private
    /// scalar. rcgen/ring serialize PKCS#8 with an inner SEC1 ECPrivateKey
    /// ASN.1 sequence, so convert it before calling `SecKeyCreateWithData`.
    static func sec1EcPrivateKeyToSecKeyData(_ der: Data) throws -> Data {
        let bytes = [UInt8](der)
        guard bytes.count > 2, bytes[0] == 0x30 else {
            throw AdminHttpError.identityCreation("ECPrivateKey missing outer SEQUENCE")
        }

        var i = 1
        let (_, outerLenBytes) = try readDerLength(bytes, at: i)
        i += outerLenBytes

        var privateScalar: Data?
        var publicPoint: Data?

        while i < bytes.count {
            let tag = bytes[i]
            i += 1
            let (contentLen, lenBytes) = try readDerLength(bytes, at: i)
            i += lenBytes
            let contentStart = i
            let contentEnd = contentStart + contentLen
            guard contentEnd <= bytes.count else {
                throw AdminHttpError.identityCreation("ECPrivateKey element overruns buffer")
            }

            switch tag {
            case 0x04:
                privateScalar = Data(bytes[contentStart..<contentEnd])
            case 0xA1:
                publicPoint = try ecPublicPointFromExplicitBitString(bytes, start: contentStart, end: contentEnd)
            default:
                break
            }

            i = contentEnd
        }

        guard let privateScalar, privateScalar.count == 32 else {
            throw AdminHttpError.identityCreation("ECPrivateKey missing P-256 private scalar")
        }

        let point: Data
        if let publicPoint {
            point = publicPoint
        } else {
            let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateScalar)
            point = privateKey.publicKey.x963Representation
        }

        guard point.count == 65, point.first == 0x04 else {
            throw AdminHttpError.identityCreation("ECPrivateKey missing uncompressed P-256 public point")
        }

        var keyData = Data()
        keyData.append(point)
        keyData.append(privateScalar)
        return keyData
    }

    static func ecPublicPointFromExplicitBitString(
        _ bytes: [UInt8],
        start: Int,
        end: Int
    ) throws -> Data {
        guard start < end, bytes[start] == 0x03 else {
            throw AdminHttpError.identityCreation("ECPrivateKey public key missing BIT STRING")
        }
        var i = start + 1
        let (bitStringLen, lenBytes) = try readDerLength(bytes, at: i)
        i += lenBytes
        let bitStringEnd = i + bitStringLen
        guard bitStringEnd <= end, i < bitStringEnd else {
            throw AdminHttpError.identityCreation("ECPrivateKey public key BIT STRING invalid")
        }
        let unusedBits = bytes[i]
        guard unusedBits == 0 else {
            throw AdminHttpError.identityCreation("ECPrivateKey public key has unsupported unused bits")
        }
        i += 1
        return Data(bytes[i..<bitStringEnd])
    }

    /// Pulls the inner `OCTET STRING` (the actual private key bytes) out of
    /// the PKCS8 envelope. Very small hand-rolled DER walker — sufficient
    /// for the well-formed outputs that `phantom-keygen` emits.
    static func unwrapPkcs8PrivateKey(_ der: Data) throws -> Data {
        // Find the last OCTET STRING tag (0x04) at the top level — PKCS8's
        // `privateKey` field. This is a coarse heuristic that holds for
        // the canonical encoding.
        let bytes = [UInt8](der)
        var i = 0
        // Skip outer SEQUENCE header.
        guard bytes.count > 2, bytes[0] == 0x30 else {
            throw AdminHttpError.identityCreation("PKCS8 envelope missing outer SEQUENCE")
        }
        i = 1
        let (_, lenBytes) = try readDerLength(bytes, at: i)
        i += lenBytes

        while i < bytes.count {
            let tag = bytes[i]
            let tagStart = i
            i += 1
            let (contentLen, lb) = try readDerLength(bytes, at: i)
            i += lb
            let contentStart = i
            i += contentLen

            if tag == 0x04 {
                let end = min(contentStart + contentLen, bytes.count)
                return Data(bytes[contentStart..<end])
            }
            // Move past this element — safety-clamp i to a valid index.
            if i > bytes.count {
                throw AdminHttpError.identityCreation("PKCS8 walk overshot at tag \(tag) start \(tagStart)")
            }
        }
        throw AdminHttpError.identityCreation("PKCS8 missing privateKey OCTET STRING")
    }

    static func readDerLength(_ bytes: [UInt8], at offset: Int) throws -> (Int, Int) {
        guard offset < bytes.count else {
            throw AdminHttpError.identityCreation("DER length read out of bounds")
        }
        let first = bytes[offset]
        if first & 0x80 == 0 {
            return (Int(first), 1)
        }
        let numBytes = Int(first & 0x7F)
        guard numBytes > 0, offset + numBytes < bytes.count else {
            throw AdminHttpError.identityCreation("DER long-form length invalid")
        }
        var value = 0
        for k in 1...numBytes {
            value = (value << 8) | Int(bytes[offset + k])
        }
        return (value, 1 + numBytes)
    }

    static func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        outer: for i in 0...(haystack.count - needle.count) {
            for j in 0..<needle.count where haystack[i + j] != needle[j] {
                continue outer
            }
            return true
        }
        return false
    }

    /// Adds the cert + key as a temporary keychain entry, queries it back
    /// as a `SecIdentity`, then removes the keychain entries. The
    /// randomized label avoids collisions across concurrent invocations.
    static func buildIdentityViaKeychain(
        certificate: SecCertificate,
        privateKey: SecKey
    ) throws -> SecIdentity {
        let label = "ghoststream.admin.\(UUID().uuidString)"

        let certAttrs: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ]
        let certStatus = SecItemAdd(certAttrs as CFDictionary, nil)
        if certStatus != errSecSuccess && certStatus != errSecDuplicateItem {
            throw AdminHttpError.identityCreation("SecItemAdd(cert) = \(certStatus)")
        }

        let keyAttrs: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrLabel as String: label,
        ]
        let keyStatus = SecItemAdd(keyAttrs as CFDictionary, nil)
        if keyStatus != errSecSuccess && keyStatus != errSecDuplicateItem {
            // Clean up the cert we just added before bailing.
            SecItemDelete(certAttrs as CFDictionary)
            throw AdminHttpError.identityCreation("SecItemAdd(key) = \(keyStatus)")
        }

        defer {
            SecItemDelete(certAttrs as CFDictionary)
            SecItemDelete(keyAttrs as CFDictionary)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &result)
        if st != errSecSuccess || result == nil {
            throw AdminHttpError.identityCreation("SecItemCopyMatching(identity) = \(st)")
        }
        // Force-cast is safe: kSecClass = kSecClassIdentity guarantees
        // the result is a SecIdentity.
        let identity = result as! SecIdentity
        return identity
    }
}

#if DEBUG
enum AdminIdentityTestSupport {
    @MainActor
    static func inspectPkcs8(_ der: Data) throws -> (CFString, Data, Int?) {
        let keyMaterial = try AdminHttpClient.inspectPkcs8(der)
        return (keyMaterial.keyType, keyMaterial.keyData, keyMaterial.keySizeInBits)
    }
}
#endif

// MARK: - Hashing helper

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Type-erased Encodable

/// Lightweight type eraser so we can keep `body: Encodable?` at the API
/// surface without conditional generics.
private struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self.encodeFn = wrapped.encode
    }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

// MARK: - Active profile entitlements

/// Refreshes per-profile admin/subscription cache through the currently
/// connected tunnel. Admin state is identity-specific, so only the active
/// profile is refreshed automatically.
@MainActor
enum ProfileEntitlementRefresher {
    private static let log = Logger(subsystem: "com.ghoststream.vpn", category: "entitlements")

    static func refreshActiveProfileIfConnected(
        profilesStore: ProfilesStore
    ) async -> VpnProfile? {
        guard let profile = profilesStore.activeProfile else {
            return nil
        }

        let appState = VpnStateManager.shared.state
        if !shouldAttemptRefresh(appState: appState) {
            let systemStatus = await VpnTunnelController().currentStatus()
            guard shouldAttemptRefresh(appState: appState, systemStatus: systemStatus) else {
                return nil
            }
        }

        return await refresh(profile: profile, profilesStore: profilesStore)
    }

    static func shouldAttemptRefresh(
        appState: VpnState,
        systemStatus: NEVPNStatus? = nil
    ) -> Bool {
        if case .disconnecting = appState {
            return false
        }
        switch appState {
        case .connected, .connecting:
            return true
        case .disconnected, .disconnecting, .error:
            break
        }
        switch systemStatus {
        case .connected, .connecting, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting, .none:
            return false
        @unknown default:
            return false
        }
    }

    static func refresh(
        profile: VpnProfile,
        profilesStore: ProfilesStore
    ) async -> VpnProfile? {
        guard let certPem = profile.certPem, !certPem.isEmpty,
              let keyPem = profile.keyPem, !keyPem.isEmpty,
              let baseURL = adminBaseURL(for: profile)
        else {
            return nil
        }

        do {
            let client = try AdminHttpClient(
                baseURL: baseURL,
                clientCertPem: certPem,
                clientKeyPem: keyPem,
                pinnedServerCertFp: profile.cachedAdminServerCertFp
            )
            let me = try await client.getMe()
            var updated = currentProfile(for: profile, in: profilesStore)
            updated.cachedIsAdmin = me.isAdmin
            if let fp = client.lastServerCertFp {
                updated.cachedAdminServerCertFp = fp
            }

            if me.isAdmin,
               let match = try? await matchingClient(
                    client: client,
                    profile: profile,
                    selfInfo: me
               ) {
                updated.cachedExpiresAt = match.expiresAt
                updated.cachedEnabled = match.enabled
            }

            profilesStore.update(updated)
            return updated
        } catch {
            log.error("Admin entitlement refresh failed for profile \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func adminBaseURL(for profile: VpnProfile) -> URL? {
        URL(string: "https://\(gatewayHost(forTunAddr: profile.tunAddr)):8080")
    }

    static func gatewayHost(forTunAddr tunAddr: String) -> String {
        AdminGateway.host(forTunAddr: tunAddr)
    }

    static func sameTunIP(_ lhs: String, _ rhs: String) -> Bool {
        tunIP(lhs) == tunIP(rhs)
    }

    static func subscriptionText(for profile: VpnProfile) -> String? {
        guard profile.cachedEnabled != false else {
            return AppStrings.localized("dashboard.subscription.client_disabled", fallback: "Client disabled")
        }
        guard let expiresAt = profile.cachedExpiresAt else {
            return profile.cachedEnabled != nil
                ? AppStrings.localized("dashboard.subscription.unlimited", fallback: "Unlimited subscription")
                : nil
        }
        let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
        guard remaining > 0 else {
            return AppStrings.localized("dashboard.subscription.expired", fallback: "Subscription expired")
        }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        if days > 0 {
            return String(
                format: AppStrings.localized(
                    "native.dashboard.subscription.remaining.format",
                    fallback: "Subscription: %lldd %lldh"
                ),
                days,
                hours
            )
        }
        if hours > 0 {
            return String(
                format: AppStrings.localized(
                    "native.dashboard.subscription.hours.format",
                    fallback: "Subscription: %lldh"
                ),
                hours
            )
        }
        return AppStrings.localized(
            "native.dashboard.subscription.less_than_hour",
            fallback: "Subscription: < 1h"
        )
    }

    private static func matchingClient(
        client: AdminHttpClient,
        profile: VpnProfile,
        selfInfo: AdminSelfInfo
    ) async throws -> AdminClient? {
        let clients = try await client.listClients()
        return clients.first { sameTunIP($0.tunAddr, profile.tunAddr) }
            ?? clients.first { $0.name == selfInfo.name }
    }

    private static func currentProfile(
        for profile: VpnProfile,
        in profilesStore: ProfilesStore
    ) -> VpnProfile {
        var current = profilesStore.profiles.first(where: { $0.id == profile.id }) ?? profile
        current.certPem = current.certPem ?? profile.certPem
        current.keyPem = current.keyPem ?? profile.keyPem
        return current
    }

    private static func tunIP(_ tunAddr: String) -> String {
        tunAddr
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
