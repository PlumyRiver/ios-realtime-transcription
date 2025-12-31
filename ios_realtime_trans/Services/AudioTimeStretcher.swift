//
//  AudioTimeStretcher.swift
//  ios_realtime_trans
//
//  音頻時間拉伸處理器（1.5x 加速）
//  用於加速音頻以節省 STT 成本（節省 33%）
//
//  ⭐️ 改進版算法：Overlap-Add with Hanning Window
//  - 使用重疊窗口消除塊邊界不連續
//  - 使用漢寧窗進行平滑過渡
//  - 使用 Apple Accelerate 框架 (vDSP) 優化性能
//
//  經過 /tmp 測試驗證：
//  - 1.5x 加速對所有主要語言都有效
//  - 2.0x 對日語、土耳其語、泰語、印尼語、烏克蘭語無效
//  - 因此統一使用 1.5x 以確保所有語言的兼容性
//

import Foundation
import Accelerate  // Apple 高性能計算框架

/// 音頻時間拉伸處理器
/// 使用 Overlap-Add 算法 + 漢寧窗 + vDSP 優化
/// 節省 33% STT 成本，兼容所有語言
class AudioTimeStretcher {

    // MARK: - Configuration

    /// 加速倍率（1.5 = 節省 33% 成本）
    /// 經測試，1.5x 對所有語言都有效，2.0x 對部分語言（日語等）無效
    private let speedRatio: Float = 1.5

    /// 採樣率
    private let sampleRate: Int = 16000

    /// 分析窗口大小（30ms @ 16kHz = 480 samples）
    /// 較小的窗口 = 更好的時間精度，對語音來說 20-40ms 是最佳範圍
    private let windowSize: Int = 480

    /// 重疊比例（50% 重疊）
    /// 重疊越大，過渡越平滑，但計算量也越大
    private let overlapRatio: Float = 0.5

    /// 輸入步長（分析跳躍大小）
    private var inputHopSize: Int { Int(Float(windowSize) * (1 - overlapRatio)) }

    /// 輸出步長（合成跳躍大小）= 輸入步長 / 加速倍率
    private var outputHopSize: Int { Int(Float(inputHopSize) / speedRatio) }

    /// 最小緩衝大小（至少需要一個完整窗口 + 一個跳躍）
    private var minBufferSize: Int { windowSize + inputHopSize }

    // MARK: - Pre-computed Data

    /// 漢寧窗係數（Float 版本，用於 vDSP 計算）
    private var hanningWindow: [Float] = []

    /// 輸出緩衝區的重疊累加區
    private var overlapBuffer: [Float] = []

    // MARK: - State

    /// 輸入緩衝區
    private var inputBuffer: [Int16] = []

    /// 是否啟用
    private(set) var isEnabled: Bool = false

    /// 統計：已處理的音頻時長（秒）
    private(set) var totalProcessedDuration: TimeInterval = 0

    /// 統計：節省的時長（秒）
    private(set) var savedDuration: TimeInterval = 0

    /// 處理計數器（用於控制 log 頻率）
    private var processCount: Int = 0
    private let logInterval: Int = 10  // 每 10 次打印一次

    // MARK: - Callbacks

    /// 處理完成回調（返回壓縮後的音頻數據）
    var onProcessedAudio: ((Data) -> Void)?

    // MARK: - Initialization

    init() {
        // 預計算漢寧窗
        setupHanningWindow()

        // 初始化重疊緩衝區
        overlapBuffer = [Float](repeating: 0, count: windowSize)

        print("✅ [AudioTimeStretcher] 初始化完成（Overlap-Add 改進版）")
        print("   窗口: \(windowSize) samples (\(windowSize * 1000 / sampleRate)ms)")
        print("   重疊: \(Int(overlapRatio * 100))%")
        print("   輸入步長: \(inputHopSize) samples (\(inputHopSize * 1000 / sampleRate)ms)")
        print("   輸出步長: \(outputHopSize) samples (\(outputHopSize * 1000 / sampleRate)ms)")
        print("   加速: \(speedRatio)x（節省 33%）")
    }

    /// 設置漢寧窗係數
    private func setupHanningWindow() {
        hanningWindow = [Float](repeating: 0, count: windowSize)

        // 使用 vDSP 生成漢寧窗
        // Hanning: w[n] = 0.5 * (1 - cos(2πn / (N-1)))
        var length = Int32(windowSize)
        vDSP_hann_window(&hanningWindow, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        // 歸一化窗口（確保重疊相加後能量一致）
        // 對於 50% 重疊的漢寧窗，不需要額外歸一化
    }

    // MARK: - Public Methods

    /// 啟用/禁用加速
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            print("🚀 [AudioTimeStretcher] 已啟用 \(speedRatio)x 加速（Overlap-Add + vDSP）")
        } else {
            print("⏸️ [AudioTimeStretcher] 已禁用加速")
            reset()
        }
    }

    /// 重置狀態
    func reset() {
        inputBuffer.removeAll()
        overlapBuffer = [Float](repeating: 0, count: windowSize)
        processCount = 0
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

        // 檢查緩衝區是否足夠處理
        guard inputBuffer.count >= minBufferSize else {
            return nil  // 繼續緩衝
        }

        // ⭐️ 使用 Overlap-Add 算法處理
        var allOutputSamples: [Int16] = []
        var totalInputSamples = 0
        var windowsProcessed = 0

        // 處理所有可處理的窗口
        while inputBuffer.count >= minBufferSize {
            // 執行 Overlap-Add 時間拉伸
            let stretchedSamples = processOverlapAdd()
            allOutputSamples.append(contentsOf: stretchedSamples)

            totalInputSamples += inputHopSize
            windowsProcessed += 1
        }

        guard !allOutputSamples.isEmpty else {
            return nil
        }

        // 更新統計
        let inputDuration = Double(totalInputSamples) / Double(sampleRate)
        let outputDuration = Double(allOutputSamples.count) / Double(sampleRate)
        totalProcessedDuration += inputDuration
        savedDuration += (inputDuration - outputDuration)
        processCount += windowsProcessed

        // 🚀 每 N 次打印一次即時 log
        if processCount <= windowsProcessed || processCount % logInterval < windowsProcessed {
            let totalInputMs = totalInputSamples * 1000 / sampleRate
            let totalOutputMs = allOutputSamples.count * 1000 / sampleRate
            let outputBytes = allOutputSamples.count * 2
            let savedPercent = Int((1.0 - Float(allOutputSamples.count) / Float(max(totalInputSamples, 1))) * 100)

            print("🚀 [AudioTimeStretcher] #\(processCount) (處理 \(windowsProcessed) 窗口):")
            print("   輸入: \(totalInputSamples) samples (\(totalInputMs)ms)")
            print("   輸出: \(allOutputSamples.count) samples (\(totalOutputMs)ms) = \(outputBytes) bytes")
            print("   節省: \(savedPercent)% | 累計: \(String(format: "%.1f", savedDuration))s | 緩衝: \(inputBuffer.count)")
        }

        // 轉換回 Data
        let outputData = allOutputSamples.withUnsafeBytes { Data($0) }

        // 調用回調
        onProcessedAudio?(outputData)

        return outputData
    }

    /// 強制輸出剩餘緩衝區的內容（用於結束時）
    func flush() -> Data? {
        guard isEnabled, !inputBuffer.isEmpty else {
            return nil
        }

        print("📤 [AudioTimeStretcher] Flush 剩餘 \(inputBuffer.count) samples")

        // 對剩餘數據進行簡單的時間拉伸
        let stretchedSamples = simpleTimeStretch(samples: inputBuffer)
        inputBuffer.removeAll()

        return stretchedSamples.withUnsafeBytes { Data($0) }
    }

    /// 獲取當前緩衝狀態
    var bufferStatus: String {
        let percent = Float(inputBuffer.count) / Float(minBufferSize) * 100
        return String(format: "%.0f%%", percent)
    }

    // MARK: - Overlap-Add Algorithm

    /// 處理一個 Overlap-Add 週期
    /// 返回輸出步長大小的樣本
    private func processOverlapAdd() -> [Int16] {
        guard inputBuffer.count >= windowSize else {
            return []
        }

        // 1. 取出一個窗口的數據
        let windowData = Array(inputBuffer.prefix(windowSize))

        // 2. 移除輸入步長（而不是整個窗口）- 這樣下一次處理會有重疊
        inputBuffer.removeFirst(inputHopSize)

        // 3. 轉換為 Float 用於 vDSP 處理
        var floatData = [Float](repeating: 0, count: windowSize)
        vDSP_vflt16(windowData, 1, &floatData, 1, vDSP_Length(windowSize))

        // 4. 應用漢寧窗
        var windowedData = [Float](repeating: 0, count: windowSize)
        vDSP_vmul(floatData, 1, hanningWindow, 1, &windowedData, 1, vDSP_Length(windowSize))

        // 5. 進行時間壓縮（1.5x = 輸出樣本數減少 1/3）
        // 使用線性插值進行高質量重採樣
        let compressedData = resampleWithInterpolation(windowedData, ratio: speedRatio)

        // 6. Overlap-Add：與上一個窗口的尾部重疊相加
        var outputData = [Float](repeating: 0, count: outputHopSize)

        // 重疊區域相加（前 windowSize - outputHopSize 個樣本）
        let overlapSize = min(overlapBuffer.count, compressedData.count)
        for i in 0..<overlapSize {
            if i < outputHopSize {
                outputData[i] = overlapBuffer[i] + compressedData[i]
            }
        }

        // 7. 更新重疊緩衝區（保存這次窗口的尾部，用於下次重疊）
        let newOverlapStart = min(outputHopSize, compressedData.count)
        let newOverlapSize = min(compressedData.count - newOverlapStart, windowSize)
        overlapBuffer = [Float](repeating: 0, count: windowSize)
        for i in 0..<newOverlapSize {
            let srcIdx = newOverlapStart + i
            if srcIdx < compressedData.count {
                overlapBuffer[i] = compressedData[srcIdx]
            }
        }

        // 8. 轉換回 Int16
        var int16Output = [Int16](repeating: 0, count: outputHopSize)
        var scaledOutput = outputData

        // Clipping 保護
        var minVal: Float = -32768
        var maxVal: Float = 32767
        vDSP_vclip(scaledOutput, 1, &minVal, &maxVal, &scaledOutput, 1, vDSP_Length(outputHopSize))

        // 轉換為 Int16
        vDSP_vfix16(scaledOutput, 1, &int16Output, 1, vDSP_Length(outputHopSize))

        return int16Output
    }

    /// 使用線性插值進行重採樣
    /// - Parameters:
    ///   - input: 輸入樣本
    ///   - ratio: 壓縮比（1.5 = 壓縮到 2/3）
    /// - Returns: 壓縮後的樣本
    private func resampleWithInterpolation(_ input: [Float], ratio: Float) -> [Float] {
        let outputCount = Int(Float(input.count) / ratio)
        var output = [Float](repeating: 0, count: outputCount)

        // 使用 vDSP 進行高效的線性插值
        // 對於 1.5x，每個輸出樣本對應輸入的 1.5 倍位置
        for i in 0..<outputCount {
            let srcPos = Float(i) * ratio
            let srcIdx = Int(srcPos)
            let frac = srcPos - Float(srcIdx)

            if srcIdx + 1 < input.count {
                // 線性插值：output = input[i] * (1-frac) + input[i+1] * frac
                output[i] = input[srcIdx] * (1 - frac) + input[srcIdx + 1] * frac
            } else if srcIdx < input.count {
                output[i] = input[srcIdx]
            }
        }

        return output
    }

    /// 簡單的時間拉伸（用於 flush 剩餘數據）
    private func simpleTimeStretch(samples: [Int16]) -> [Int16] {
        let outputCount = samples.count * 2 / 3
        var output = [Int16]()
        output.reserveCapacity(outputCount)

        var i = 0
        while i + 2 < samples.count {
            output.append(samples[i])
            let val1 = Int32(samples[i + 1])
            let val2 = Int32(samples[i + 2])
            output.append(Int16((val1 + val2) / 2))
            i += 3
        }

        if i < samples.count {
            output.append(samples[i])
        }

        return output
    }

    // MARK: - Debug

    /// 打印統計信息
    func printStats() {
        let savedPercent = savedDuration / max(totalProcessedDuration, 0.001) * 100
        print("📊 [AudioTimeStretcher] 統計:")
        print("   已處理: \(String(format: "%.1f", totalProcessedDuration)) 秒")
        print("   節省: \(String(format: "%.1f", savedDuration)) 秒 (\(String(format: "%.0f", savedPercent))%)")
    }
}

// MARK: - Singleton (Optional)

extension AudioTimeStretcher {
    /// 共享實例（如果需要全局訪問）
    static let shared = AudioTimeStretcher()
}
