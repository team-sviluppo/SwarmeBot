@testable import SwarmeBotUI
import CompanionCore
import XCTest

@MainActor
final class NotificationTests: XCTestCase {
    private func frame(_ kind: String = "done") throws -> NotificationFrame {
        try JSONDecoder().decode(NotificationFrame.self, from: Data("""
        {"kind":"\(kind)","botId":"b","botName":"Bot","threadId":"t","title":"Finished","body":"Done"}
        """.utf8))
    }

    func testBackgroundClosedAndMinimizedChatsNotify() throws {
        let frame = try frame()
        XCTAssertTrue(NotificationCenterBridge.shouldDeliver(isActive: false, chatVisible: true, selectedThread: "t", frame: frame))
        XCTAssertTrue(NotificationCenterBridge.shouldDeliver(isActive: true, chatVisible: false, selectedThread: "t", frame: frame))
        XCTAssertTrue(NotificationCenterBridge.shouldDeliver(isActive: true, chatVisible: true, selectedThread: "other", frame: frame))
        XCTAssertFalse(NotificationCenterBridge.shouldDeliver(isActive: true, chatVisible: true, selectedThread: "t", frame: frame))
        XCTAssertTrue(NotificationCenterBridge.shouldDeliver(isActive: true, chatVisible: true, selectedThread: "t", frame: try self.frame("approval")))
    }
}
