import CoreGraphics
import Darwin
import Foundation

/// Tells a click the user made with this Mac's own mouse or trackpad from a click some process posted.
///
/// What it relies on: the window server writes the posting process's pid into `kCGEventSourceUnixProcessID` when an
/// event is posted (`CGEventPost`, `CGEventPostToPid`), and overwrites any value the poster put in that field
/// (checked on macOS 15: a click forged with pid 0 arrives stamped with the poster's real pid). Events that come from
/// the HID system carry no posting process. So a click counts only when that field is 0 (or the window server's own
/// pid). UseMac's foreground bursts, another agent's CGEvents, Screen Sharing, Universal Control, Voice Control and
/// Switch Control all carry a pid, so none of them can answer an approval prompt.
public enum ApprovalInputCheck {
    /// Proof that the user pressed and released the mouse button on a prompt button. Only `verifyClick` makes one
    /// outside tests, so code that answers a prompt has to have seen a physical click.
    public struct PhysicalClick: Sendable, Equatable {
        public let sourcePid: Int64
        public let downTime: TimeInterval
        public let upTime: TimeInterval

        init(sourcePid: Int64, downTime: TimeInterval, upTime: TimeInterval) {
            self.sourcePid = sourcePid
            self.downTime = downTime
            self.upTime = upTime
        }
    }

    /// A button needs the prompt to be on screen this long before a press counts, so a click the user meant for
    /// whatever was under the pointer when the prompt appeared never answers it.
    public static let armingDelaySeconds: TimeInterval = 0.75
    /// A press held longer than this is not a click.
    public static let maxPressSeconds: TimeInterval = 5

    /// The pid that posted `event`, or 0 for input from the HID system. Nil when there is no event at all.
    public static func sourcePid(of event: CGEvent?) -> Int64? {
        event?.getIntegerValueField(.eventSourceUnixProcessID)
    }

    /// True for input from this Mac's own keyboard, mouse or trackpad.
    public static func isPhysical(_ event: CGEvent?) -> Bool {
        guard let pid = sourcePid(of: event) else { return false }
        return isPhysicalSource(pid: pid)
    }

    static func isPhysicalSource(pid: Int64) -> Bool {
        if pid == 0 { return true }
        if let server = windowServerPid, pid == Int64(server) { return true }
        return false
    }

    /// Checks a whole click on a prompt button. `downTime`/`upTime` are the NSEvent timestamps (seconds since boot)
    /// and `armedAt` is when the prompt's buttons went live, on the same clock.
    public static func verifyClick(
        down: CGEvent?,
        up: CGEvent?,
        downTime: TimeInterval,
        upTime: TimeInterval,
        armedAt: TimeInterval
    ) -> PhysicalClick? {
        guard let down, let up, down.type == .leftMouseDown, up.type == .leftMouseUp else { return nil }
        guard let downPid = sourcePid(of: down), let upPid = sourcePid(of: up),
              isPhysicalSource(pid: downPid), isPhysicalSource(pid: upPid) else { return nil }
        return verifyTiming(sourcePid: downPid, downTime: downTime, upTime: upTime, armedAt: armedAt)
    }

    static func verifyTiming(sourcePid: Int64, downTime: TimeInterval, upTime: TimeInterval, armedAt: TimeInterval) -> PhysicalClick? {
        guard downTime >= armedAt, upTime >= downTime, upTime - downTime <= maxPressSeconds else { return nil }
        return PhysicalClick(sourcePid: sourcePid, downTime: downTime, upTime: upTime)
    }

    /// The window server's pid, looked up once.
    static let windowServerPid: pid_t? = lookUpWindowServerPid()

    private static func lookUpWindowServerPid() -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return nil }
        for proc in procs.prefix(size / stride) {
            var comm = proc.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name == "WindowServer" {
                return proc.kp_proc.p_pid
            }
        }
        return nil
    }
}
