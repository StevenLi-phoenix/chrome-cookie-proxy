import XCTest
@testable import CookieCore

/// 向量全部来自独立工具：
///   key  = python3 hashlib.pbkdf2_hmac('sha1', b'peanuts', b'saltysalt', 1003, 16)
///   密文 = openssl enc -aes-128-cbc -K <key> -iv 20202020202020202020202020202020
final class CryptoTests: XCTestCase {
    static let keyHex = "d9a09d499b4e1b7461f28e67972c6dbd"

    func testPBKDF2MatchesPythonHashlib() throws {
        let key = try CookieCrypto.deriveKey(password: Data("peanuts".utf8))
        XCTAssertEqual(key.hex, Self.keyHex)
    }

    func testDecryptsV10Hello() throws {
        let key = Data(hex: Self.keyHex)
        let blob = Data("v10".utf8) + Data(hex: "8690a7cb3c7871d1a16024469ce35b43")
        // meta version < 24：没有 host 哈希前缀
        let result = CookieCrypto.decrypt(blob, hostKey: ".youtube.com", key: key, metaVersion: 23)
        XCTAssertEqual(try result.get(), "hello")
    }

    func testDecryptsVersion24StripsHostHash() throws {
        // 明文 = sha256(".youtube.com") + "world"
        let key = Data(hex: Self.keyHex)
        let blob = Data("v10".utf8) + Data(hex:
            "dfedf6a25de951793acf97b7e0577316f5009863e773f7845c5b1d94c4dd66306305798ba383f11d978ebec06fb6fa49")
        let result = CookieCrypto.decrypt(blob, hostKey: ".youtube.com", key: key, metaVersion: 24)
        XCTAssertEqual(try result.get(), "world")
        // 更高的 schema 版本同样适用
        XCTAssertEqual(try CookieCrypto.decrypt(blob, hostKey: ".youtube.com", key: key, metaVersion: 99).get(), "world")
    }

    func testVersion24HostMismatchIsFailure() {
        let key = Data(hex: Self.keyHex)
        let blob = Data("v10".utf8) + Data(hex:
            "dfedf6a25de951793acf97b7e0577316f5009863e773f7845c5b1d94c4dd66306305798ba383f11d978ebec06fb6fa49")
        XCTAssertEqual(
            CookieCrypto.decrypt(blob, hostKey: ".google.com", key: key, metaVersion: 24),
            .failure(.hostHashMismatch))
    }

    func testVersion24WithoutHashPrefixIsFailure() {
        // 旧格式密文（"hello" 只有 5 字节明文）放在 v24 库里：不足 32 字节
        let key = Data(hex: Self.keyHex)
        let blob = Data("v10".utf8) + Data(hex: "8690a7cb3c7871d1a16024469ce35b43")
        XCTAssertEqual(
            CookieCrypto.decrypt(blob, hostKey: ".youtube.com", key: key, metaVersion: 24),
            .failure(.hostHashMismatch))
    }

    func testUnsupportedPrefixes() {
        let key = Data(hex: Self.keyHex)
        let body = Data(hex: "8690a7cb3c7871d1a16024469ce35b43")
        for prefix in ["v11", "v20", "xyz", "v1"] {
            XCTAssertEqual(
                CookieCrypto.decrypt(Data(prefix.utf8) + body, hostKey: "a.com", key: key, metaVersion: 23),
                .failure(.unsupportedPrefix), prefix)
        }
        XCTAssertEqual(CookieCrypto.decrypt(Data(), hostKey: "a.com", key: key, metaVersion: 23),
                       .failure(.unsupportedPrefix))
    }

    func testBadCiphertextIsFailureNotCrash() {
        let key = Data(hex: Self.keyHex)
        // 长度不是 16 的倍数
        XCTAssertEqual(
            CookieCrypto.decrypt(Data("v10".utf8) + Data([1, 2, 3]), hostKey: "a.com", key: key, metaVersion: 23),
            .failure(.decryptFailed))
        // v10 后面什么都没有
        XCTAssertEqual(
            CookieCrypto.decrypt(Data("v10".utf8), hostKey: "a.com", key: key, metaVersion: 23),
            .failure(.decryptFailed))
        // 错误的 key：几乎一定是填充错误
        let wrongKey = Data(repeating: 7, count: 16)
        let blob = Data("v10".utf8) + Data(hex: "8690a7cb3c7871d1a16024469ce35b43")
        if case .success(let s) = CookieCrypto.decrypt(blob, hostKey: "a.com", key: wrongKey, metaVersion: 23) {
            XCTAssertNotEqual(s, "hello")
        }
    }

    func testInvalidUTF8IsFailure() {
        // printf "\xff\xfe\xfd" 经 openssl 加密
        let key = Data(hex: Self.keyHex)
        let blob = Data("v10".utf8) + Data(hex: "2549ba7febd0879a0b76e4aac75188a0")
        XCTAssertEqual(CookieCrypto.decrypt(blob, hostKey: "a.com", key: key, metaVersion: 23),
                       .failure(.invalidUTF8))
    }
}
