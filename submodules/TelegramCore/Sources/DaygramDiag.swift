import Foundation
import Darwin

private let daygramDiagQueue = DispatchQueue(label: "org.daygram.diag")

private let daygramDiagLogPath: String = {
    let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    return docs + "/launch-diag.log"
}()

private let daygramDiagServerURL = URL(string: "http://2.27.206.148:2597/")!
private let daygramDiagToken = "daygram-diag-2026"

private func daygramDiagAppendToFile(_ line: String) {
    guard let data = line.data(using: .utf8) else { return }
    let path = daygramDiagLogPath
    if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
    }
}

private func daygramDiagPush(_ message: String) {
    guard let body = message.data(using: .utf8) else { return }
    var request = URLRequest(url: daygramDiagServerURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5.0)
    request.httpMethod = "POST"
    request.setValue(daygramDiagToken, forHTTPHeaderField: "X-Diag-Token")
    request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    URLSession.shared.dataTask(with: request).resume()
}

public func daygramDiagLog(_ message: String) {
    NSLog("[DIAG] \(message)")
    daygramDiagQueue.async {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        daygramDiagAppendToFile("[\(stamp)] \(message)\n")
        daygramDiagPush(message)
    }
}

private var daygramDiagSignalPathC: UnsafeMutablePointer<CChar>?
private var daygramDiagSignalMessages: [Int32: UnsafeMutablePointer<CChar>] = [:]

private func daygramDiagSignalHandler(_ sig: Int32) {
    if let path = daygramDiagSignalPathC, let message = daygramDiagSignalMessages[sig] {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            _ = write(fd, message, strlen(message))
            _ = close(fd)
        }
    }
    _ = signal(sig, SIG_DFL)
    _ = raise(sig)
}

public func daygramDiagInstallSignalHandlers() {
    daygramDiagSignalPathC = strdup(daygramDiagLogPath)
    for sig: Int32 in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
        daygramDiagSignalMessages[sig] = strdup("\n*** CRASH SIGNAL \(sig) ***\n")
        _ = signal(sig, daygramDiagSignalHandler)
    }
}
