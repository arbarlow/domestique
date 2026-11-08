import DQCore
import Foundation
import XCTest

final class CreationTimelineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func timeline() -> CreationTimeline {
        CreationTimeline(stages: [(id: "a", title: "A"), (id: "b", title: "B"), (id: "c", title: "C")])
    }

    func testBeginEndsThePreviousStageAndRecordsDurations() {
        var t = timeline()
        t.begin("a", at: at(0))
        t.begin("b", at: at(5))
        XCTAssertEqual(t.stages[0].status, .done)
        XCTAssertEqual(t.stages[0].duration(), 5)
        XCTAssertEqual(t.current?.id, "b")
        XCTAssertEqual(t.stages[1].duration(now: at(7)), 2)
        XCTAssertEqual(t.total(now: at(7)), 7)
    }

    func testSkippedStagesAreDropped() {
        var t = timeline()
        t.begin("a", at: at(0))
        t.begin("c", at: at(1))
        XCTAssertEqual(t.stages.map(\.id), ["a", "c"])
    }

    func testRestartingAStageIsIgnored() {
        var t = timeline()
        t.begin("a", at: at(0))
        t.begin("b", at: at(1))
        t.begin("a", at: at(2))
        XCTAssertEqual(t.current?.id, "b")
        XCTAssertEqual(t.stages[0].finishedAt, at(1))
    }

    func testLateDetailOnAFinishedStageIsIgnored() {
        var t = timeline()
        t.begin("a", detail: "one", at: at(0))
        t.setDetail("a", "two")
        XCTAssertEqual(t.stages[0].detail, "two")
        t.begin("b", at: at(1))
        t.setDetail("a", "three")
        XCTAssertEqual(t.stages[0].detail, "two")
    }

    func testFinishStopsTheClockAndFindsTheSlowest() {
        var t = timeline()
        t.begin("a", at: at(0))
        t.begin("b", at: at(1))
        t.finish(at: at(10))
        XCTAssertEqual(t.stages.map(\.id), ["a", "b"])
        XCTAssertNil(t.current)
        XCTAssertEqual(t.total(now: at(99)), 10)
        XCTAssertEqual(t.slowest?.id, "b")
    }

    func testFailMarksTheRunningStageAndKeepsThePlan() {
        var t = timeline()
        t.begin("a", at: at(0))
        t.fail(at: at(3))
        XCTAssertTrue(t.hasFailed)
        XCTAssertEqual(t.stages[0].status, .failed)
        XCTAssertEqual(t.stages[0].duration(), 3)
        XCTAssertEqual(t.stages[1].status, .pending)
    }

    func testFormat() {
        XCTAssertEqual(CreationTimeline.format(0.4), "<1s")
        XCTAssertEqual(CreationTimeline.format(34.9), "34s")
        XCTAssertEqual(CreationTimeline.format(102), "1m 42s")
    }
}
