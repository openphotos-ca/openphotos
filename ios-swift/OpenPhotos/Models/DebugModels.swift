import Foundation

struct BgTaskInfo: Identifiable {
    let id = UUID()
    let desc: String
    let state: String
    let sent: Int64
    let expected: Int64
    let responseCode: Int?
}

