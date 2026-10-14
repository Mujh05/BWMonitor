import Foundation
import Security

/// Converts unencrypted RSA PKCS#1/PKCS#8 PEM in memory for Citadel's OpenSSH
/// reader. The original file is never changed; imported keys stay in Keychain.
enum RSAPEMImport {
    static func openSSH(_ text: String) throws -> String {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") { return text }
        let pkcs8 = text.contains("BEGIN PRIVATE KEY")
        guard text.contains("BEGIN RSA PRIVATE KEY") || pkcs8,
              !text.contains("ENCRYPTED"), !text.contains("Proc-Type:") else { throw MobileConnectionError.unsupportedKey }
        let payload = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { throw MobileConnectionError.unsupportedKey }
        var reader = DERReader(bytes: Array(bytes))
        var sequence = DERReader(bytes: try reader.read(tag: 0x30))
        var pkcs1 = bytes
        if pkcs8 {
            _ = try sequence.read(tag: 0x02)
            var algorithm = DERReader(bytes: try sequence.read(tag: 0x30))
            guard try algorithm.read(tag: 0x06) == [0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01] else { throw MobileConnectionError.unsupportedKey }
            pkcs1 = Data(try sequence.read(tag: 0x04))
            var wrapper = DERReader(bytes: Array(pkcs1))
            sequence = DERReader(bytes: try wrapper.read(tag: 0x30))
        }
        var validationError: Unmanaged<CFError>?
        guard SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &validationError) != nil else {
            throw MobileConnectionError.unsupportedKey
        }
        guard try sequence.read(tag: 0x02) == [0] else { throw MobileConnectionError.unsupportedKey }
        var integers: [[UInt8]] = []
        for _ in 0..<8 { integers.append(try sequence.read(tag: 0x02)) }
        guard sequence.remaining == 0 else { throw MobileConnectionError.unsupportedKey }
        let n = integers[0], e = integers[1], d = integers[2], p = integers[3], q = integers[4], iqmp = integers[7]
        var publicBlob = Data()
        string(Data("ssh-rsa".utf8), into: &publicBlob); string(Data(e), into: &publicBlob); string(Data(n), into: &publicBlob)
        var privateBlob = Data()
        let check = UInt32.random(in: UInt32.min...UInt32.max)
        number(check, into: &privateBlob); number(check, into: &privateBlob)
        string(Data("ssh-rsa".utf8), into: &privateBlob)
        for value in [n,e,d,iqmp,p,q] { string(Data(value), into: &privateBlob) }
        string(Data(), into: &privateBlob)
        var padding: UInt8 = 1
        while privateBlob.count % 8 != 0 { privateBlob.append(padding); padding += 1 }
        var envelope = Data("openssh-key-v1\0".utf8)
        string(Data("none".utf8), into: &envelope); string(Data("none".utf8), into: &envelope); string(Data(), into: &envelope)
        number(1, into: &envelope); string(publicBlob, into: &envelope); string(privateBlob, into: &envelope)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + envelope.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private static func number(_ value: UInt32, into data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private static func string(_ bytes: Data, into data: inout Data) { number(UInt32(bytes.count), into: &data); data.append(bytes) }

    private struct DERReader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }
        mutating func read(tag: UInt8) throws -> [UInt8] {
            guard remaining >= 2, bytes[offset] == tag else { throw MobileConnectionError.unsupportedKey }
            offset += 1
            let first = bytes[offset]; offset += 1
            var length = Int(first)
            if first & 0x80 != 0 {
                let count = Int(first & 0x7F)
                guard count > 0, count <= 4, remaining >= count else { throw MobileConnectionError.unsupportedKey }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[offset]); offset += 1 }
            }
            guard length <= remaining else { throw MobileConnectionError.unsupportedKey }
            let result = Array(bytes[offset..<(offset + length)]); offset += length
            return result
        }
    }
}
