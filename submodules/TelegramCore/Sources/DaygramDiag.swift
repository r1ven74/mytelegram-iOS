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

public func daygramDiagFatalSync(_ message: String) {
    NSLog("[DIAG-FATAL] \(message)")
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(stamp)] \(message)\n"
    daygramDiagAppendToFile(line)
    line.withCString { cstr in
        if daygramDiagUdpFd >= 0 {
            _ = send(daygramDiagUdpFd, cstr, strlen(cstr), 0)
        }
    }
    guard let body = line.data(using: .utf8) else { return }
    var request = URLRequest(url: daygramDiagServerURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 2.0)
    request.httpMethod = "POST"
    request.setValue(daygramDiagToken, forHTTPHeaderField: "X-Diag-Token")
    request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { _, _, _ in
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 1.5)
}

private var daygramDiagUdpFd: Int32 = -1

public func daygramDiagPrepareUdp() {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(2596).bigEndian
    addr.sin_addr.s_addr = inet_addr("2.27.206.148")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connected == 0 {
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        daygramDiagUdpFd = fd
    } else {
        close(fd)
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
        if daygramDiagUdpFd >= 0 {
            _ = send(daygramDiagUdpFd, message, strlen(message), 0)
        }
    }
    _ = signal(sig, SIG_DFL)
    _ = raise(sig)
}

public func daygramDiagInstallSignalHandlers() {
    daygramDiagSignalPathC = strdup(daygramDiagLogPath)
    let signalNames: [(Int32, String)] = [
        (SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"),
        (SIGILL, "SIGILL"), (SIGFPE, "SIGFPE"), (SIGTRAP, "SIGTRAP"),
        (SIGPIPE, "SIGPIPE"), (SIGSYS, "SIGSYS")
    ]
    for (sig, name) in signalNames {
        let text = "\n*** CRASH SIGNAL \(name)(\(sig)) ***\n"
        daygramDiagSignalMessages[sig] = strdup(text)
        _ = signal(sig, daygramDiagSignalHandler)
    }
}
