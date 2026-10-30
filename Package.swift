// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "chrome-cookie-proxy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "chrome-cookie-proxy", targets: ["chrome-cookie-proxy"]),
    ],
    targets: [
        // 全部纯逻辑；只依赖系统库（Foundation、Security、CommonCrypto、SQLite3、Darwin）。
        .target(
            name: "CookieCore",
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        .executableTarget(name: "chrome-cookie-proxy", dependencies: ["CookieCore"]),
        .testTarget(name: "CookieCoreTests", dependencies: ["CookieCore"]),
    ]
)
