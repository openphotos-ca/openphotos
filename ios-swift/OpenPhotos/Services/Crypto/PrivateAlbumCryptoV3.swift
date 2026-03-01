// SPDX-License-Identifier: MIT
// PrivateAlbumCryptoV3.swift (App integration)
//
// Ported from the CLI reference (root/PrivateAlbumCryptoV3.swift) with the following additions:
// - headerPlain now supports an optional arbitrary metadata object (JSON) to carry coarse fields
// - helper encryptFileReturningInfo that returns assetId (base58) and outer header (base64url)
// - small helpers for base58/base64url and JSON value encoding
//
import Foundation
import CryptoKit

// -------- Constants --------
private let MAGIC = Data("PAE3".utf8)
private let VERSION: UInt8 = 0x03
private let FLAG_TRAILER: UInt8 = 0x01
private let TRAILER_LEN = 4 + 2 + 2 + 32   // "TAG3" + rsv + len + tag(32)
private let GCM_TAG_LEN = 16               // 128-bit
public let PAE3_DEFAULT_CHUNK_SIZE = 1 * 1024 * 1024

// -------- Utilities --------
private extension Data {
    mutating func appendUInt32BE(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { buf in self.append(contentsOf: buf) }
    }
    mutating func appendUInt16BE(_ v: UInt16) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { buf in self.append(contentsOf: buf) }
    }
}

private func readUInt32BE(from fh: FileHandle) throws -> UInt32 {
    let d = try fh.read(upToCount: 4) ?? Data()
    guard d.count == 4 else { throw NSError(domain: "pae3", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF (u32)"]) }
    return d.withUnsafeBytes { ptr in UInt32(bigEndian: ptr.load(as: UInt32.self)) }
}

private func base64URLEncode(_ data: Data) -> String {
    let s = data.base64EncodedString()
    return s.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = (4 - (t.count % 4)) % 4
    if pad > 0 { t.append(String(repeating: "=", count: pad)) }
    return Data(base64Encoded: t)
}

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var r: UInt8 = 0
    for i in 0..<a.count { r |= a[i] ^ b[i] }
    return r == 0
}

private func randomBytes(_ n: Int) -> Data {
    var b = Data(count: n)
    _ = b.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    return b
}

private func addToIV(baseIv: Data, idx: Int) -> Data {
    precondition(baseIv.count == 12)
    var out = baseIv
    var carry = idx
    for i in stride(from: 11, through: 0, by: -1) {
        let sum = Int(out[i]) + (carry & 0xFF)
        out[i] = UInt8(sum & 0xFF)
        carry = (sum >> 8)
        if carry == 0 { break }
    }
    return out
}

private func aadForChunk(assetId: Data, idx: Int, isLast: Bool) -> Data {
    var d = Data("chunk:v3".utf8)
    d.append(assetId)
    d.appendUInt32BE(UInt32(idx))
    d.append(isLast ? 1 : 0)
    return d
}

// -------- Streaming HMAC-SHA256 --------
private struct HMACSHA256Stream {
    private var inner = SHA256()
    private let opad: Data

    init(key: Data) {
        let blockSize = 64
        let k: Data = key.count > blockSize ? Data(SHA256.hash(data: key)) : key
        var keyBlock = k
        if keyBlock.count < blockSize {
            keyBlock.append(Data(repeating: 0, count: blockSize - keyBlock.count))
        }
        var ipad = Data(count: blockSize)
        var opad = Data(count: blockSize)
        for i in 0..<blockSize {
            ipad[i] = keyBlock[i] ^ 0x36
            opad[i] = keyBlock[i] ^ 0x5c
        }
        self.opad = opad
        inner.update(data: ipad)
    }
    mutating func update(_ data: Data) { inner.update(data: data) }
    mutating func finalize() -> Data {
        let innerDigest = Data(inner.finalize())
        var outer = SHA256()
        outer.update(data: opad)
        outer.update(data: innerDigest)
        return Data(outer.finalize())
    }
}

private func hmacSha256(key: Data, data: Data) -> Data {
    var h = HMACSHA256Stream(key: key)
    h.update(data)
    return h.finalize()
}

// HKDF using HMAC stream; salt default = 32 zero bytes
private func hkdfSHA256(ikm: Data, salt: Data? = nil, info: Data, outLen: Int) -> Data {
    let saltUse = salt ?? Data(repeating: 0, count: 32)
    // Extract
    var h = HMACSHA256Stream(key: saltUse)
    h.update(ikm)
    let prk = h.finalize()
    // Expand
    var t = Data()
    var okm = Data(capacity: outLen)
    var counter: UInt8 = 1
    while okm.count < outLen {
        var hm = HMACSHA256Stream(key: prk)
        hm.update(t)
        hm.update(info)
        hm.update(Data([counter]))
        t = hm.finalize()
        let need = min(t.count, outLen - okm.count)
        okm.append(t.prefix(need))
        counter &+= 1
    }
    return okm
}

// AES-GCM helpers (ciphertext || tag)
private func aeadEncryptGCM(key: Data, iv12: Data, aad: Data, plaintext: Data) throws -> Data {
    let nonce = try AES.GCM.Nonce(data: iv12)
    let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
    var out = Data(sealed.ciphertext)
    out.append(sealed.tag)
    return out
}

private func aeadDecryptGCM(key: Data, iv12: Data, aad: Data, ciphertextAndTag: Data) throws -> Data {
    guard ciphertextAndTag.count >= GCM_TAG_LEN else {
        throw NSError(domain:"pae3", code:4, userInfo:[NSLocalizedDescriptionKey:"GCM input too short"])
    }
    let ct = ciphertextAndTag.dropLast(GCM_TAG_LEN)
    let tag = ciphertextAndTag.suffix(GCM_TAG_LEN)
    let nonce = try AES.GCM.Nonce(data: iv12)
    let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
    return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
}

// -------- Base58 (Bitcoin alphabet) for asset_id filenames --------
private let ALPHABET = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
private func base58Encode(_ data: Data) -> String {
    if data.isEmpty { return "" }
    var digits: [Int] = [0]
    for b in data { var carry = Int(b); for i in 0..<digits.count { let x = (digits[i] << 8) + carry; digits[i] = x % 58; carry = x / 58 }; while carry > 0 { digits.append(carry % 58); carry /= 58 } }
    var zeros = 0; for b in data { if b == 0 { zeros += 1 } else { break } }
    var out = String(repeating: "1", count: zeros)
    for i in stride(from: digits.count - 1, through: 0, by: -1) { out.append(ALPHABET[digits[i]]) }
    return out
}

// -------- JSON Value for metadata passthrough --------
public enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let obj = try? c.decode([String: JSONValue].self) { self = .object(obj); return }
        if let arr = try? c.decode([JSONValue].self) { self = .array(arr); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

// -------- Header models --------
private struct OuterHeader: Codable {
    let v: Int
    let asset_id: String
    let base_iv: String
    let wrap_iv: String
    let dek_wrapped: String
    let header_iv: String
    let header_ct: String
}

private struct HeaderPlain: Codable {
    let alg: String
    let created_unix: Int64
    let orig_size: Int64
    let chunk_size: Int
    let total_chunks: Int
    let metadata: [String: JSONValue]?
}

public struct PAE3EncryptionInfo {
    public let assetIdB58: String
    public let outerHeaderB64Url: String
    public let containerURL: URL
    public let plaintextSize: Int64
}

// -------- Encrypt (with return info) --------
public func pae3EncryptFileReturningInfo(umk: Data, userIdKey: Data, input: URL, output: URL, headerMetadata: [String: JSONValue]?, chunkSize: Int = PAE3_DEFAULT_CHUNK_SIZE) throws -> PAE3EncryptionInfo {
    guard let inFH = FileHandle(forReadingAtPath: input.path) else {
        throw NSError(domain:"pae3", code:5, userInfo:[NSLocalizedDescriptionKey:"Cannot open input"])
    }
    defer { try? inFH.close() }

    // Pass 1: compute asset_id (HMAC(user_id, file_bytes)) + orig size
    var idH = HMACSHA256Stream(key: userIdKey)
    var origSize: Int64 = 0
    while true {
        let buf = try inFH.read(upToCount: 512 * 1024) ?? Data()
        if buf.isEmpty { break }
        idH.update(buf)
        origSize += Int64(buf.count)
    }
    let idFull = idH.finalize()
    let assetId = idFull.prefix(16)

    // Keys & IVs
    let wrapKey = hkdfSHA256(ikm: umk, info: Data("hkdf:wrap:v3".utf8), outLen: 32)
    let wrapIv  = randomBytes(12)
    let dek     = randomBytes(32)
    let headerIv = randomBytes(12)
    let baseIv  = randomBytes(12)

    // AADs
    let aadHeader = Data("header:v3".utf8) + assetId
    let aadWrap   = Data("wrap:v3".utf8)   + assetId

    let totalChunks = Int((origSize + Int64(chunkSize) - 1) / Int64(chunkSize))
    let nowSec = Int64(Date().timeIntervalSince1970)

    // headerPlain with metadata
    let hp = HeaderPlain(alg: "AES-GCM-256", created_unix: nowSec, orig_size: origSize, chunk_size: chunkSize, total_chunks: totalChunks, metadata: headerMetadata)
    let headerPlainJson = try JSONEncoder().encode(hp)
    let headerCt = try aeadEncryptGCM(key: dek, iv12: headerIv, aad: aadHeader, plaintext: headerPlainJson)

    // Wrap DEK
    let dekWrapped = try aeadEncryptGCM(key: wrapKey, iv12: wrapIv, aad: aadWrap, plaintext: dek)

    // Build header JSON
    let oh = OuterHeader(
        v: 3,
        asset_id: base64URLEncode(assetId),
        base_iv:  base64URLEncode(baseIv),
        wrap_iv:  base64URLEncode(wrapIv),
        dek_wrapped: base64URLEncode(dekWrapped),
        header_iv: base64URLEncode(headerIv),
        header_ct: base64URLEncode(headerCt)
    )
    let headerBytes = try JSONEncoder().encode(oh)

    // Prepare output
    FileManager.default.createFile(atPath: output.path, contents: nil)
    guard let outFH = FileHandle(forWritingAtPath: output.path) else {
        throw NSError(domain:"pae3", code:6, userInfo:[NSLocalizedDescriptionKey:"Cannot open output"])
    }
    defer { try? outFH.close() }

    // Write container header
    var pre = Data()
    pre.append(MAGIC)
    pre.append(VERSION)
    pre.append(FLAG_TRAILER)
    pre.appendUInt32BE(UInt32(headerBytes.count))
    try outFH.write(contentsOf: pre)
    try outFH.write(contentsOf: headerBytes)

    // Trailer MAC (web-compatible iterative HMAC)
    let dekPhys = hkdfSHA256(ikm: dek, info: Data("hkdf:dek:phys:v3".utf8), outLen: 32)
    var macState = Data()

    // Pass 2: stream encrypt chunks
    try inFH.seek(toOffset: 0)
    var idx = 0
    while true {
        let buf = try inFH.read(upToCount: chunkSize) ?? Data()
        if buf.isEmpty { break }
        let isLast = (idx == totalChunks - 1)
        let iv = addToIV(baseIv: baseIv, idx: idx)
        let aad = aadForChunk(assetId: assetId, idx: idx, isLast: isLast)
        let ct = try aeadEncryptGCM(key: dek, iv12: iv, aad: aad, plaintext: buf)

        var len = Data(); len.appendUInt32BE(UInt32(ct.count))
        try outFH.write(contentsOf: len)
        try outFH.write(contentsOf: ct)

        // Match web: macUpdate(len); macUpdate(ct)
        macState = hmacSha256(key: dekPhys, data: macState + len)
        macState = hmacSha256(key: dekPhys, data: macState + ct)
        idx += 1
    }

    // Trailer
    let tag = hmacSha256(key: dekPhys, data: macState)
    var trailer = Data("TAG3".utf8)
    trailer.appendUInt16BE(0)          // reserved
    trailer.appendUInt16BE(32)         // tag length
    trailer.append(tag)                // 32 bytes
    try outFH.write(contentsOf: trailer)

    let assetIdB58 = base58Encode(Data(assetId))
    let outerHeaderB64Url = base64URLEncode(headerBytes)
    return PAE3EncryptionInfo(assetIdB58: assetIdB58, outerHeaderB64Url: outerHeaderB64Url, containerURL: output, plaintextSize: origSize)
}

// -------- Decrypt (for in-app viewing if needed) --------
public func pae3DecryptFile(umk: Data, userIdKey: Data, input: URL, output: URL) throws {
    guard let fh = FileHandle(forReadingAtPath: input.path) else {
        throw NSError(domain:"pae3", code:7, userInfo:[NSLocalizedDescriptionKey:"Cannot open input"])
    }
    defer { try? fh.close() }

    let fileSizeNum = try FileManager.default.attributesOfItem(atPath: input.path)[.size] as! NSNumber
    let fileSize = UInt64(truncating: fileSizeNum)
    guard fileSize >= UInt64(10 + TRAILER_LEN) else { throw NSError(domain:"pae3", code:8, userInfo:[NSLocalizedDescriptionKey:"File too small"]) }

    // magic/version/flags/headerLen
    let magic = try fh.read(upToCount: 4) ?? Data()
    guard magic == MAGIC else { throw NSError(domain:"pae3", code:9, userInfo:[NSLocalizedDescriptionKey:"Bad magic"]) }
    let ver = try fh.read(upToCount: 1)![0]
    guard ver == VERSION else { throw NSError(domain:"pae3", code:10, userInfo:[NSLocalizedDescriptionKey:"Unsupported version"]) }
    let flags = try fh.read(upToCount: 1)![0]
    let hasTrailer = (flags & FLAG_TRAILER) != 0
    let headerLen = try readUInt32BE(from: fh)

    // Read header
    let headerBytes = try fh.read(upToCount: Int(headerLen)) ?? Data()
    guard headerBytes.count == Int(headerLen) else { throw NSError(domain:"pae3", code:11, userInfo:[NSLocalizedDescriptionKey:"Invalid header length"]) }

    // Compute positions
    var pos: UInt64 = 10 + UInt64(headerLen)
    let trailerPos: UInt64 = fileSize - UInt64(TRAILER_LEN)
    guard hasTrailer && trailerPos > pos else { throw NSError(domain:"pae3", code:12, userInfo:[NSLocalizedDescriptionKey:"Missing/invalid trailer"]) }

    // Parse header
    let oh = try JSONDecoder().decode(OuterHeader.self, from: headerBytes)

    guard oh.v == 3 else { throw NSError(domain:"pae3", code:13, userInfo:[NSLocalizedDescriptionKey:"Header v != 3"]) }
    guard let assetId = base64URLDecode(oh.asset_id), assetId.count == 16 else { throw NSError(domain:"pae3", code:14, userInfo:[NSLocalizedDescriptionKey:"Bad asset_id"]) }
    guard let baseIv  = base64URLDecode(oh.base_iv),  baseIv.count == 12 else { throw NSError(domain:"pae3", code:15, userInfo:[NSLocalizedDescriptionKey:"Bad base_iv"]) }
    guard let wrapIv  = base64URLDecode(oh.wrap_iv),  wrapIv.count == 12 else { throw NSError(domain:"pae3", code:16, userInfo:[NSLocalizedDescriptionKey:"Bad wrap_iv"]) }
    guard let dekWrapped = base64URLDecode(oh.dek_wrapped) else { throw NSError(domain:"pae3", code:17, userInfo:[NSLocalizedDescriptionKey:"Bad dek_wrapped"]) }
    guard let headerIv = base64URLDecode(oh.header_iv), headerIv.count == 12 else { throw NSError(domain:"pae3", code:18, userInfo:[NSLocalizedDescriptionKey:"Bad header_iv"]) }
    guard let headerCt = base64URLDecode(oh.header_ct) else { throw NSError(domain:"pae3", code:19, userInfo:[NSLocalizedDescriptionKey:"Bad header_ct"]) }

    // Derive and unwrap DEK
    let wrapKey = hkdfSHA256(ikm: umk, info: Data("hkdf:wrap:v3".utf8), outLen: 32)
    let aadWrap = Data("wrap:v3".utf8) + assetId
    let dek = try aeadDecryptGCM(key: wrapKey, iv12: wrapIv, aad: aadWrap, ciphertextAndTag: dekWrapped)

    // Decrypt headerPlain
    let aadHeader = Data("header:v3".utf8) + assetId
    _ = try aeadDecryptGCM(key: dek, iv12: headerIv, aad: aadHeader, ciphertextAndTag: headerCt)

    // Prepare output & HMACs
    FileManager.default.createFile(atPath: output.path, contents: nil)
    guard let outFH = FileHandle(forWritingAtPath: output.path) else {
        throw NSError(domain:"pae3", code:21, userInfo:[NSLocalizedDescriptionKey:"Cannot open output"])
    }
    defer { try? outFH.close() }

    // Trailer MAC (web-compatible iterative HMAC)
    let dekPhys = hkdfSHA256(ikm: dek, info: Data("hkdf:dek:phys:v3".utf8), outLen: 32)
    var macState = Data()
    var idH = HMACSHA256Stream(key: userIdKey)

    // Stream chunks until trailer
    var idx = 0
    while pos < trailerPos {
        let clen = try readUInt32BE(from: fh)
        pos += 4
        let left = trailerPos - pos
        guard UInt64(clen) <= left else { throw NSError(domain:"pae3", code:23, userInfo:[NSLocalizedDescriptionKey:"Invalid chunk length"]) }
        // Determine if this is the last chunk before reading it (pos currently points to chunk start)
        let isLast = (pos + UInt64(clen) == trailerPos)
        let ct = try fh.read(upToCount: Int(clen)) ?? Data()
        guard ct.count == Int(clen) else { throw NSError(domain:"pae3", code:24, userInfo:[NSLocalizedDescriptionKey:"EOF in chunk"]) }
        pos += UInt64(ct.count)

        var lenData = Data(); lenData.appendUInt32BE(clen)
        macState = hmacSha256(key: dekPhys, data: macState + lenData)
        macState = hmacSha256(key: dekPhys, data: macState + ct)

        let iv = addToIV(baseIv: baseIv, idx: idx)
        let aad = aadForChunk(assetId: assetId, idx: idx, isLast: isLast)
        let plain = try aeadDecryptGCM(key: dek, iv12: iv, aad: aad, ciphertextAndTag: ct)

        try outFH.write(contentsOf: plain)
        idH.update(plain)
        idx += 1
    }

    // Trailer
    try fh.seek(toOffset: trailerPos)
    let tagMagic = try fh.read(upToCount: 4) ?? Data()
    guard tagMagic == Data("TAG3".utf8) else { throw NSError(domain:"pae3", code:27, userInfo:[NSLocalizedDescriptionKey:"Bad trailer magic"]) }
    _ = try fh.read(upToCount: 2) // reserved
    let tagLenData = try fh.read(upToCount: 2) ?? Data()
    let tagLen = UInt16(tagLenData[0]) << 8 | UInt16(tagLenData[1])
    guard tagLen == 32 else { throw NSError(domain:"pae3", code:30, userInfo:[NSLocalizedDescriptionKey:"Unexpected tag length"]) }
    let tag = try fh.read(upToCount: Int(tagLen)) ?? Data()

    let tag2 = hmacSha256(key: dekPhys, data: macState)
    guard constantTimeEqual(tag, tag2) else { throw NSError(domain:"pae3", code:31, userInfo:[NSLocalizedDescriptionKey:"Trailer HMAC mismatch"]) }

    // Verify asset_id matches HMAC(user_id, plaintext)
    let assetId2 = idH.finalize().prefix(16)
    guard constantTimeEqual(assetId, assetId2) else {
        throw NSError(domain:"pae3", code:32, userInfo:[NSLocalizedDescriptionKey:"asset_id mismatch for given USER_ID and plaintext"])
    }
}
