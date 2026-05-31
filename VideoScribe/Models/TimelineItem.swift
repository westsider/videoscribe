import Foundation

enum TimelineItem {
    case segment(start: TimeInterval, end: TimeInterval, text: String)
    case frame(t: TimeInterval, imageData: Data)

    var time: TimeInterval {
        switch self {
        case .segment(let start, _, _): return start
        case .frame(let t, _): return t
        }
    }
}

enum TimestampFormatter {
    static func label(_ t: TimeInterval, totalDuration: TimeInterval) -> String {
        let secs = Int(t.rounded())
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if totalDuration >= 3600 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
