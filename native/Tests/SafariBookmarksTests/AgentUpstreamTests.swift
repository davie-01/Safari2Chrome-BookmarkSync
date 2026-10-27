import XCTest
@testable import AgentCore

final class AgentUpstreamTests: XCTestCase {
    /// A stand-in agent: a Unix socket at `path`. Like the real one it binds first and
    /// listens a moment later, so the socket file shows up before connections are accepted.
    private final class FakeAgent {
        let fd: Int32
        init(path: String, listenAfter: TimeInterval = 0.3) throws {
            unlink(path)
            var addr = try unixAddress(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            precondition(r == 0)
            Thread.sleep(forTimeInterval: listenAfter)
            precondition(listen(fd, 4) == 0)
        }
        /// Accepts one connection (nil after `timeout`) with the first line it sent.
        func acceptOne(timeout: TimeInterval = 5) -> (Int32, String?)? {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return nil }
            let c = accept(fd, nil, nil)
            return (c, LineReader(fd: c).next().flatMap { String(data: $0, encoding: .utf8) })
        }
        func stop() { close(fd) }
    }

    /// Frames the host writes for the extension, read off a pipe.
    private final class Frames {
        let pipe = Pipe()
        func next(timeout: TimeInterval = 3) -> [String: Any]? {
            let fd = pipe.fileHandleForReading.fileDescriptor
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(timeout * 1000)) > 0, let len = readExactly(fd, 4) else { return nil }
            let n = len.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            return readExactly(fd, Int(n)).flatMap { try? JSON.object($0) }
        }
    }

    func testReconnectsWhenTheAgentComesAndGoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("up\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("agent.sock").path
        let frames = Frames()
        let kicks = NSLock()
        var kicked = 0
        let up = AgentUpstream(socketPath: path, out: FrameWriter(fd: frames.pipe.fileHandleForWriting.fileDescriptor),
                               hello: Data(#"{"type":"host.hello"}"#.utf8), kickstart: { kicks.lock(); kicked += 1; kicks.unlock() })
        up.start()
        // agent down: no connection, answered at once, launchd nudged once (not per request)
        XCTAssertNil(up.current())
        XCTAssertNil(up.current())
        Thread.sleep(forTimeInterval: 0.1)
        kicks.lock(); XCTAssertEqual(kicked, 1); kicks.unlock()

        // agent starts: the host connects by itself, says hello, and tells the extension
        var agent = try FakeAgent(path: path)
        guard var (conn, first) = agent.acceptOne() else { return XCTFail("host did not connect to the new agent") }
        XCTAssertEqual(first, #"{"type":"host.hello"}"#)
        XCTAssertEqual(frames.next()?["event"] as? String, "agent.available")
        XCTAssertNotNil(up.current())

        // agent restarts: the extension hears it went, then that it is back
        close(conn); agent.stop()
        XCTAssertEqual(frames.next()?["event"] as? String, "agent.disconnected")
        agent = try FakeAgent(path: path)
        guard let again = agent.acceptOne() else { return XCTFail("host did not reconnect after the agent restarted") }
        (conn, first) = again
        XCTAssertEqual(first, #"{"type":"host.hello"}"#)
        XCTAssertEqual(frames.next()?["event"] as? String, "agent.available")
        close(conn); agent.stop()
    }
}
