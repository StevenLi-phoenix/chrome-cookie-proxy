import CookieCore
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

do {
    switch try CLI.parse(Array(CommandLine.arguments.dropFirst()), home: NSHomeDirectory()) {
    case .help:
        print(CLI.usage)
    case .serve(let options):
        try Service.serve(options)
    }
} catch let error as CLIError {
    fail("chrome-cookie-proxy: \(error)\n\(CLI.usage)", code: 2)
} catch {
    fail("chrome-cookie-proxy: \(error)", code: 1)
}
