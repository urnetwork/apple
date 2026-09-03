import Testing
@testable import URnetwork

struct IpFamilyTests {

    @Test func clampsOutOfRangeToAuto() {
        #expect(IpFamily.clamp(-1) == IpFamily.auto)
        #expect(IpFamily.clamp(7) == IpFamily.auto)
        #expect(IpFamily.clamp(IpFamily.force4) == IpFamily.force4)
        #expect(IpFamily.clamp(IpFamily.force6) == IpFamily.force6)
    }

    @Test func cyclesAutoToForce4ToForce6AndBack() {
        #expect(IpFamily.next(IpFamily.auto) == IpFamily.force4)
        #expect(IpFamily.next(IpFamily.force4) == IpFamily.force6)
        #expect(IpFamily.next(IpFamily.force6) == IpFamily.auto)
    }

    @Test func namesEveryPolicy() {
        #expect(IpFamily.name(IpFamily.auto) == "Automatic")
        #expect(IpFamily.name(IpFamily.force4) == "Force IPv4")
        #expect(IpFamily.name(IpFamily.force6) == "Force IPv6")
    }

    // The detail line has to distinguish auto-with-nothing-learned from
    // auto-with-a-demotion, or the row looks identical whether the heuristic
    // fired or not.
    @Test func autoDetailReportsALearnedDemotion() {
        let quiet = IpFamily.detail(IpFamily.auto, status: "")
        let demoted = IpFamily.detail(IpFamily.auto, status: "IPv6 demoted for 4m (2 strikes)")
        #expect(quiet != demoted)
        #expect(demoted.contains("IPv6 demoted"))
    }

    // A force is a force: the status is irrelevant because the ledger is not
    // consulted while one is set.
    @Test func forceDetailIgnoresStatus() {
        let withStatus = IpFamily.detail(IpFamily.force4, status: "IPv6 demoted for 4m (2 strikes)")
        let without = IpFamily.detail(IpFamily.force4, status: "")
        #expect(withStatus == without)
    }
}
