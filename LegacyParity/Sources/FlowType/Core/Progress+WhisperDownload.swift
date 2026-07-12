import Foundation

extension Progress {
    /// Hub 写入的估算速率（字节/秒）；尝试常见 `ProgressUserInfoKey` 的 raw 值。
    var flowTypeEstimatedThroughputBytesPerSecond: Double? {
        let dict = userInfo
        for raw in ["throughput", "NSProgressThroughputKey"] {
            let key = ProgressUserInfoKey(rawValue: raw)
            if let d = dict[key] as? Double, d > 0 { return d }
            if let n = dict[key] as? NSNumber {
                let d = n.doubleValue
                if d > 0 { return d }
            }
        }
        for (key, value) in dict where key.rawValue.localizedCaseInsensitiveContains("throughput") {
            if let d = value as? Double, d > 0 { return d }
            if let n = value as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
        }
        return nil
    }
}
