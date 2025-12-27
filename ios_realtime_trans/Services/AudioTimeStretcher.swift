//
//  AudioTimeStretcher.swift
//  ios_realtime_trans
//
//  音頻時間拉伸處理器（WSOLA 算法）
//  用於 2x 加速音頻以節省 STT 成本
//
//  原理：使用 WSOLA (Waveform Similarity Overlap-Add) 算法
//  在不改變音高的情況下加速音頻
//

import Foundation
import Accelerate

/// 音頻時間拉伸處理器
/// 使用 250ms 緩衝，2x 加速，輸出 125ms 壓縮音頻
class AudioTimeStretcher {

    // MARK: - Configuration

    /// 加速倍率（2.0 = 雙倍速度，節省 50% 成本）
    private let speedRatio: Float = 2.0

    /// 採樣率
    private let sampleRate: Int = 16000

    /// 緩衝大小（250ms @ 16kHz = 4000 samples）
    private let bufferSamples: Int = 4000

    /// 分析窗口大小（25ms @ 16kHz = 400 samples）
    private let windowSize: Int = 400

    /// 重疊區域（12.5ms @ 16kHz = 200 samples）
    private let overlapSize: Int = 200

    /// 搜索範圍（用於尋找最佳匹配位置）
    private let searchRange: Int = 100

    // MARK: - State

    /// 輸入緩衝區
    private var inputBuffer: [Int16] = []

    /// 上一個輸出塊的尾部（用於重疊）
    private var previousTail: [Float] = []

    /// 是否啟用
    private(set) var isEnabled: Bool = false

    /// 統計：已處理的音頻時長（秒）
    private(set) var totalProcessedDuration: TimeInterval = 0

    /// 統計：節省的時長（秒）
    private(set) var savedDuration: TimeInterval = 0

    // MARK: - Callbacks

    /// 處理完成回調（返回壓縮後的音頻數據）
    var onProcessedAudio: ((Data) -> Void)?

    // MARK: - Initialization

    init() {
        print("✅ [AudioTimeStretcher] 初始化完成")
        print("   緩衝: \(bufferSamples) samples (\(bufferSamples * 1000 / sampleRate)ms)")
        print("   加速: \(speedRatio)x")
        print("   輸出: \(Int(Float(bufferSamples) / speedRatio)) samples (\(Int(Float(bufferSamples) / speedRatio) * 1000 / sampleRate)ms)")
    }

    // MARK: - Public Methods

    /// 啟用/禁用加速
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            print("🚀 [AudioTimeStretcher] 已啟用 \(speedRatio)x 加速")
        } else {
            print("⏸️ [AudioTimeStretcher] 已禁用加速")
            reset()
        }
    }

    /// 重置狀態
    func reset() {
        inputBuffer.removeAll()
        previousTail.removeAll()
        print("🔄 [AudioTimeStretcher] 已重置")
    }

    /// 輸入音頻數據
    /// - Parameter data: PCM Int16 音頻數據
    /// - Returns: 如果緩衝已滿，返回壓縮後的數據；否則返回 nil
    func process(data: Data) -> Data? {
        guard isEnabled else {
            // 未啟用時直接返回原始數據
            return data
        }

        // 將 Data 轉換為 Int16 數組
        let samples = data.withUnsafeBytes { rawPtr -> [Int16] in
            let int16Ptr = rawPtr.bindMemory(to: Int16.self)
            return Array(int16Ptr)
        }

        // 添加到緩衝區
        inputBuffer.append(contentsOf: samples)

        // 檢查緩衝區是否已滿
        guard inputBuffer.count >= bufferSamples else {
            return nil  // 繼續緩衝
        }

        // 取出一個完整的緩衝塊
        let chunk = Array(inputBuffer.prefix(bufferSamples))
        inputBuffer.removeFirst(bufferSamples)

        // 執行時間拉伸
        let stretchedSamples = timeStretch(samples: chunk)

        // 更新統計
        let inputDuration = Double(bufferSamples) / Double(sampleRate)
        let outputDuration = Double(stretchedSamples.count) / Double(sampleRate)
        totalProcessedDuration += inputDuration
        savedDuration += (inputDuration - outputDuration)

        // 轉換回 Data
        let outputData = stretchedSamples.withUnsafeBytes { Data($0) }

        // 調用回調
        onProcessedAudio?(outputData)

        return outputData
    }

    /// 強制輸出剩餘緩衝區的內容（用於結束時）
    func flush() -> Data? {
        guard isEnabled, !inputBuffer.isEmpty else {
            return nil
        }

        let chunk = inputBuffer
        inputBuffer.removeAll()

        // 對剩餘數據進行時間拉伸
        let stretchedSamples = timeStretch(samples: chunk)

        return stretchedSamples.withUnsafeBytes { Data($0) }
    }

    /// 獲取當前緩衝狀態
    var bufferStatus: String {
        let percent = Float(inputBuffer.count) / Float(bufferSamples) * 100
        return String(format: "%.0f%%", percent)
    }

    // MARK: - WSOLA Algorithm

    /// 時間拉伸核心算法（WSOLA 簡化版）
    private func timeStretch(samples: [Int16]) -> [Int16] {
        // 轉換為 Float 進行處理
        var floatSamples = samples.map { Float($0) / Float(Int16.max) }

        // 計算輸出長度
        let outputLength = Int(Float(floatSamples.count) / speedRatio)
        var output = [Float](repeating: 0, count: outputLength)

        // 輸入步進（每次移動的樣本數）
        let inputStep = windowSize
        // 輸出步進（壓縮後的步進）
        let outputStep = Int(Float(inputStep) / speedRatio)

        var inputPos = 0
        var outputPos = 0

        // 創建漢寧窗（用於平滑過渡）
        let hanningWindow = createHanningWindow(size: windowSize)

        while inputPos + windowSize <= floatSamples.count && outputPos + windowSize <= outputLength {
            // 獲取當前窗口
            let windowStart = inputPos
            let windowEnd = min(inputPos + windowSize, floatSamples.count)
            var window = Array(floatSamples[windowStart..<windowEnd])

            // 如果有上一個塊的尾部，尋找最佳匹配位置並進行重疊
            if !previousTail.isEmpty && previousTail.count == overlapSize {
                // 尋找最佳匹配位置
                let bestOffset = findBestMatch(
                    target: previousTail,
                    source: window,
                    searchRange: min(searchRange, window.count - overlapSize)
                )

                // 調整窗口位置
                if bestOffset > 0 && bestOffset + windowSize <= floatSamples.count - inputPos {
                    window = Array(floatSamples[(inputPos + bestOffset)..<min(inputPos + bestOffset + windowSize, floatSamples.count)])
                }

                // 重疊淡入淡出
                for i in 0..<min(overlapSize, window.count, previousTail.count) {
                    let fadeOut = Float(overlapSize - i) / Float(overlapSize)
                    let fadeIn = Float(i) / Float(overlapSize)
                    if outputPos - overlapSize + i >= 0 && outputPos - overlapSize + i < output.count {
                        output[outputPos - overlapSize + i] = previousTail[i] * fadeOut + window[i] * fadeIn
                    }
                }
            }

            // 應用窗函數並寫入輸出
            for i in 0..<min(window.count, windowSize) {
                let outIdx = outputPos + i
                if outIdx < output.count {
                    // 對於重疊區域以外的部分直接寫入
                    if i >= overlapSize || previousTail.isEmpty {
                        output[outIdx] = window[i] * hanningWindow[i]
                    }
                }
            }

            // 保存當前窗口的尾部（用於下一次重疊）
            if window.count >= overlapSize {
                previousTail = Array(window.suffix(overlapSize))
            }

            // 移動位置
            inputPos += inputStep
            outputPos += outputStep
        }

        // 轉換回 Int16
        return output.prefix(outputLength).map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }
    }

    /// 創建漢寧窗
    private func createHanningWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        for i in 0..<size {
            window[i] = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(size - 1)))
        }
        return window
    }

    /// 尋找最佳匹配位置（最小化波形差異）
    private func findBestMatch(target: [Float], source: [Float], searchRange: Int) -> Int {
        guard searchRange > 0, target.count > 0 else { return 0 }

        var bestOffset = 0
        var bestCorrelation: Float = -.greatestFiniteMagnitude

        for offset in 0..<min(searchRange, source.count - target.count) {
            var correlation: Float = 0
            for i in 0..<min(target.count, source.count - offset) {
                correlation += target[i] * source[offset + i]
            }

            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestOffset = offset
            }
        }

        return bestOffset
    }

    // MARK: - Debug

    /// 打印統計信息
    func printStats() {
        print("📊 [AudioTimeStretcher] 統計:")
        print("   已處理: \(String(format: "%.1f", totalProcessedDuration)) 秒")
        print("   節省: \(String(format: "%.1f", savedDuration)) 秒 (\(String(format: "%.0f", savedDuration / max(totalProcessedDuration, 0.001) * 100))%)")
    }
}

// MARK: - Singleton (Optional)

extension AudioTimeStretcher {
    /// 共享實例（如果需要全局訪問）
    static let shared = AudioTimeStretcher()
}
