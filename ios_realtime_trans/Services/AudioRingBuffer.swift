//
//  AudioRingBuffer.swift
//  ios_realtime_trans
//
//  音頻環形緩衝區 - 儲存最近 N 秒的音頻數據
//  用於經濟模式自動語言切換時重新發送音頻
//

import Foundation

/// 音頻環形緩衝區
/// 儲存最近幾秒的 PCM 音頻數據，支持完整讀取或按時間段讀取
class AudioRingBuffer {

    // MARK: - Properties

    /// 緩衝區容量（秒）
    private let capacitySeconds: TimeInterval

    /// 採樣率
    private let sampleRate: Int

    /// 每個樣本的字節數（Int16 = 2 bytes）
    private let bytesPerSample: Int = 2

    /// 緩衝區大小（bytes）
    private let bufferSize: Int

    /// 音頻數據緩衝區
    private var buffer: Data

    /// 寫入位置
    private var writeIndex: Int = 0

    /// 已寫入的總字節數（用於判斷緩衝區是否已滿）
    private var totalBytesWritten: Int = 0

    /// 線程安全鎖
    private let lock = NSLock()

    // MARK: - Initialization

    /// 初始化環形緩衝區
    /// - Parameters:
    ///   - capacitySeconds: 緩衝區容量（秒），預設 5 秒
    ///   - sampleRate: 採樣率，預設 16000 Hz
    init(capacitySeconds: TimeInterval = 5.0, sampleRate: Int = 16000) {
        self.capacitySeconds = capacitySeconds
        self.sampleRate = sampleRate
        self.bufferSize = Int(Double(sampleRate) * capacitySeconds) * bytesPerSample
        self.buffer = Data(count: bufferSize)

        print("🔄 [AudioRingBuffer] 初始化: \(capacitySeconds)秒, \(bufferSize) bytes")
    }

    // MARK: - Public Methods

    /// 寫入音頻數據
    /// - Parameter data: PCM Int16 音頻數據
    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        var remainingData = data

        while !remainingData.isEmpty {
            // 計算這次可以寫入的字節數
            let spaceToEnd = bufferSize - writeIndex
            let bytesToWrite = min(remainingData.count, spaceToEnd)

            // 寫入數據
            buffer.replaceSubrange(writeIndex..<(writeIndex + bytesToWrite),
                                   with: remainingData.prefix(bytesToWrite))

            // 更新位置
            writeIndex = (writeIndex + bytesToWrite) % bufferSize
            totalBytesWritten += bytesToWrite

            // 移除已寫入的數據
            remainingData = remainingData.dropFirst(bytesToWrite)
        }
    }

    /// 讀取所有緩衝的音頻數據（按時間順序）
    /// - Returns: 完整的音頻數據
    func readAll() -> Data {
        lock.lock()
        defer { lock.unlock() }

        // 如果緩衝區還沒滿，只返回已寫入的數據
        if totalBytesWritten < bufferSize {
            return buffer.prefix(min(totalBytesWritten, bufferSize))
        }

        // 緩衝區已滿，需要從 writeIndex 開始讀取（最舊的數據）
        var result = Data()
        result.append(buffer.suffix(from: writeIndex))  // 從 writeIndex 到結尾
        result.append(buffer.prefix(writeIndex))         // 從開頭到 writeIndex

        return result
    }

    /// 讀取最近 N 秒的音頻數據
    /// - Parameter seconds: 要讀取的秒數
    /// - Returns: 音頻數據
    func readLast(_ seconds: TimeInterval) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let bytesToRead = min(Int(Double(sampleRate) * seconds) * bytesPerSample,
                              min(totalBytesWritten, bufferSize))

        if totalBytesWritten < bufferSize {
            // 緩衝區還沒滿
            let startIndex = max(0, totalBytesWritten - bytesToRead)
            return buffer.subdata(in: startIndex..<totalBytesWritten)
        }

        // 緩衝區已滿，計算讀取位置
        var readIndex = (writeIndex - bytesToRead + bufferSize) % bufferSize
        var result = Data()
        var remaining = bytesToRead

        while remaining > 0 {
            let toEnd = bufferSize - readIndex
            let toRead = min(remaining, toEnd)
            result.append(buffer.subdata(in: readIndex..<(readIndex + toRead)))
            readIndex = (readIndex + toRead) % bufferSize
            remaining -= toRead
        }

        return result
    }

    /// 清空緩衝區
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        writeIndex = 0
        totalBytesWritten = 0
        buffer = Data(count: bufferSize)

        print("🗑️ [AudioRingBuffer] 已清空")
    }

    /// 獲取當前緩衝的音頻時長（秒）
    var bufferedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        let bytes = min(totalBytesWritten, bufferSize)
        return Double(bytes) / Double(sampleRate * bytesPerSample)
    }

    /// 獲取緩衝區是否有數據
    var hasData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalBytesWritten > 0
    }

    /// 打印統計信息
    func printStats() {
        lock.lock()
        let bytes = min(totalBytesWritten, bufferSize)
        let duration = Double(bytes) / Double(sampleRate * bytesPerSample)
        let isFull = totalBytesWritten >= bufferSize
        lock.unlock()

        print("📊 [AudioRingBuffer] 統計:")
        print("   容量: \(capacitySeconds)秒 (\(bufferSize) bytes)")
        print("   已緩衝: \(String(format: "%.2f", duration))秒 (\(bytes) bytes)")
        print("   狀態: \(isFull ? "已滿" : "未滿")")
    }
}
