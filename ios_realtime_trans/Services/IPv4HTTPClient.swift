//
//  IPv4HTTPClient.swift
//  ios_realtime_trans
//
//  自製 HTTPS 客戶端，強制 IPv4，繞過 iOS Happy Eyeballs
//  用於網路 IPv6 不通時，避免等 10-15 秒才 fallback IPv4
//

import Foundation
import Network
import Darwin

enum IPv4HTTPError: Error {
    case invalidURL
    case dnsFailed(String)
    case connectionFailed(String)
    case timeout
    case invalidResponse
    case httpError(Int, Data?)
}

final class IPv4HTTPClient {
    static let shared = IPv4HTTPClient()

    /// POST 請求（HTTPS + 強制 IPv4 + TLS SNI）
    func post(
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) async throws -> (Data, Int) {
        guard let host = url.host,
              let portValue = UInt16(exactly: url.port ?? 443) else {
            print("❌ [IPv4HTTP] 無效 URL: \(url)")
            throw IPv4HTTPError.invalidURL
        }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }

        print("🌐 [IPv4HTTP] POST \(host)\(path)")

        // 1) 只解析 IPv4
        let t0 = Date()
        let ipv4: String
        do {
            ipv4 = try await resolveIPv4(hostname: host)
        } catch {
            print("❌ [IPv4HTTP] DNS 失敗: \(error)")
            throw error
        }
        print("🌐 [IPv4HTTP] IPv4 = \(ipv4) (DNS \(Int(Date().timeIntervalSince(t0)*1000))ms)")

        // 2) 建 HTTP/1.1 請求
        var reqStr = "POST \(path) HTTP/1.1\r\n"
        reqStr += "Host: \(host)\r\n"
        reqStr += "Connection: close\r\n"
        reqStr += "User-Agent: ios_realtime_trans/1.0\r\n"
        for (k, v) in headers {
            reqStr += "\(k): \(v)\r\n"
        }
        // POST 必須帶 Content-Length（即使為 0），否則 Cloud Run 會關連線
        reqStr += "Content-Length: \(body?.count ?? 0)\r\n"
        reqStr += "\r\n"
        var reqData = Data(reqStr.utf8)
        if let body = body { reqData.append(body) }
        print("🌐 [IPv4HTTP] 請求 (\(reqData.count) bytes):\n\(reqStr)")

        // 3) TLS + SNI 連接 IPv4 位址
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, host)
        let params = NWParameters(tls: tlsOptions)
        params.requiredInterfaceType = .other  // 不限制介面
        guard let port = NWEndpoint.Port(rawValue: portValue) else {
            throw IPv4HTTPError.invalidURL
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(ipv4),
            port: port,
            using: params
        )

        // 4) 執行請求
        return try await perform(connection: connection, data: reqData, timeout: timeout)
    }

    // MARK: - IPv4 DNS 解析

    private func resolveIPv4(hostname: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET  // ⭐️ 只要 IPv4
                hints.ai_socktype = SOCK_STREAM

                var result: UnsafeMutablePointer<addrinfo>?
                let err = getaddrinfo(hostname, nil, &hints, &result)
                guard err == 0, let first = result else {
                    cont.resume(throwing: IPv4HTTPError.dnsFailed("getaddrinfo err=\(err)"))
                    return
                }
                defer { freeaddrinfo(result) }

                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                let ip = String(cString: buf)
                guard !ip.isEmpty else {
                    cont.resume(throwing: IPv4HTTPError.dnsFailed("empty ip"))
                    return
                }
                cont.resume(returning: ip)
            }
        }
    }

    // MARK: - 執行 NWConnection 請求

    private func perform(
        connection: NWConnection,
        data: Data,
        timeout: TimeInterval
    ) async throws -> (Data, Int) {
        let queue = DispatchQueue(label: "IPv4HTTPClient")

        return try await withCheckedThrowingContinuation { cont in
            nonisolated(unsafe) var resumed = false
            func resumeOnce(_ result: Result<(Data, Int), Error>) {
                queue.async {
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    cont.resume(with: result)
                }
            }

            // 超時計時器
            queue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(.failure(IPv4HTTPError.timeout))
            }

            connection.stateUpdateHandler = { state in
                print("🌐 [IPv4HTTP] NWConnection 狀態: \(state)")
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error = error {
                            print("❌ [IPv4HTTP] send 失敗: \(error)")
                            resumeOnce(.failure(IPv4HTTPError.connectionFailed(error.localizedDescription)))
                            return
                        }
                        Self.receiveAll(connection: connection, buffer: Data()) { result in
                            switch result {
                            case .success(let raw):
                                print("🌐 [IPv4HTTP] 收到 \(raw.count) bytes")
                                let headPreview = String(data: raw.prefix(300), encoding: .utf8) ?? "non-utf8"
                                print("🌐 [IPv4HTTP] 原始回應前 300 bytes:\n\(headPreview)")
                                if let parsed = Self.parseHTTP(raw) {
                                    print("🌐 [IPv4HTTP] 解析結果: status=\(parsed.1), body=\(parsed.0.count) bytes")
                                    let bodyPreview = String(data: parsed.0.prefix(200), encoding: .utf8) ?? "non-utf8"
                                    print("🌐 [IPv4HTTP] body 前 200 bytes: \(bodyPreview)")
                                    resumeOnce(.success(parsed))
                                } else {
                                    print("❌ [IPv4HTTP] HTTP 解析失敗")
                                    resumeOnce(.failure(IPv4HTTPError.invalidResponse))
                                }
                            case .failure(let err):
                                print("❌ [IPv4HTTP] 接收失敗: \(err)")
                                resumeOnce(.failure(err))
                            }
                        }
                    })
                case .failed(let error):
                    print("❌ [IPv4HTTP] NWConnection failed: \(error)")
                    resumeOnce(.failure(IPv4HTTPError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    resumeOnce(.failure(IPv4HTTPError.connectionFailed("cancelled")))
                case .waiting(let error):
                    print("⚠️ [IPv4HTTP] NWConnection waiting: \(error)")
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// 遞迴接收所有資料直到連線關閉
    private static func receiveAll(
        connection: NWConnection,
        buffer: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { chunk, _, isComplete, error in
            if let error = error {
                completion(.failure(IPv4HTTPError.connectionFailed(error.localizedDescription)))
                return
            }
            var newBuffer = buffer
            if let chunk = chunk { newBuffer.append(chunk) }
            if isComplete {
                completion(.success(newBuffer))
            } else {
                receiveAll(connection: connection, buffer: newBuffer, completion: completion)
            }
        }
    }

    /// 解析 HTTP/1.1 response → (body, statusCode)
    /// 支援 chunked transfer encoding
    private static func parseHTTP(_ raw: Data) -> (Data, Int)? {
        // 找 \r\n\r\n 分隔 header 和 body
        guard let sep = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
        let headerData = raw.subdata(in: 0..<sep.lowerBound)
        let bodyData = raw.subdata(in: sep.upperBound..<raw.count)

        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { return nil }

        // 解析 status code
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }

        // 檢查是否 chunked
        let isChunked = headerStr.lowercased().contains("transfer-encoding: chunked")
        let finalBody = isChunked ? dechunk(bodyData) : bodyData

        return (finalBody, status)
    }

    /// 解 chunked transfer encoding
    private static func dechunk(_ data: Data) -> Data {
        var result = Data()
        var pos = 0
        while pos < data.count {
            // 找 chunk size line
            guard let crlf = data.range(of: Data([0x0D, 0x0A]), in: pos..<data.count) else { break }
            let sizeLine = data.subdata(in: pos..<crlf.lowerBound)
            guard let sizeStr = String(data: sizeLine, encoding: .utf8),
                  let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            pos = crlf.upperBound
            if size == 0 { break }  // 結束
            guard pos + size <= data.count else { break }
            result.append(data.subdata(in: pos..<pos + size))
            pos += size + 2  // 跳過資料 + \r\n
        }
        return result
    }
}
