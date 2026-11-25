//
//  TransportTeardownTests.swift
//  SignalRSwiftPackageTests
//
//  Regression tests for transports that never opened (WebSockets) or never released their HTTP
//  request when the connection was stopped (Server-Sent Events, long polling). Leaked requests
//  filled the per-host connection limit of an HTTP/1.1 server, after which no request to that host
//  (negotiate, send, abort) could start until the app was restarted.
//

import Foundation
import Network
import XCTest
import Alamofire
@testable import SignalRSwift

final class TransportTeardownTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - WebSockets

    func testWebSocketStartOpensTheSocketWithoutAnHTTPRequest() throws {
        let server = try HandshakeRecordingServer()
        defer { server.stop() }
        let port = try XCTUnwrap(server.waitForPort(timeout: 5))

        let connection = makeConnection(url: "http://127.0.0.1:\(port)/signalr/")
        connection.transportConnectTimeout = 5
        let transport = WebSocketTransport()

        transport.start(connection: connection, connectionData: "[]", completionHandler: nil)

        let requestLine = try XCTUnwrap(server.waitForRequestLine(timeout: 5), "The WebSocket handshake never reached the server")
        XCTAssertTrue(requestLine.hasPrefix("GET /signalr/connect?"), requestLine)
        XCTAssertTrue(requestLine.contains("transport=webSockets"), requestLine)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "Opening a WebSocket must not send an HTTP request: \(StubURLProtocol.requests)")

        transport.abort(connection: connection, timeout: -1, connectionData: nil)
    }

    // MARK: - Server-Sent Events

    func testServerSentEventsAbortCancelsTheEventStream() throws {
        let connection = makeConnection(url: "https://signalr.test/signalr/")
        connection.transportConnectTimeout = 30
        let transport = ServerSentEventsTransport()

        transport.start(connection: connection, connectionData: "[]", completionHandler: nil)
        XCTAssertTrue(StubURLProtocol.waitForRequest(pathSuffix: "/connect", timeout: 5), "The event stream was not opened")

        transport.abort(connection: connection, timeout: 2, connectionData: "[]")

        XCTAssertTrue(StubURLProtocol.waitForStop(pathSuffix: "/connect", timeout: 5), "The event stream stayed open after abort")
    }

    func testServerSentEventsAbortWithoutServerCallStillCancelsTheEventStream() throws {
        let connection = makeConnection(url: "https://signalr.test/signalr/")
        connection.transportConnectTimeout = 30
        let transport = ServerSentEventsTransport()

        transport.start(connection: connection, connectionData: "[]", completionHandler: nil)
        XCTAssertTrue(StubURLProtocol.waitForRequest(pathSuffix: "/connect", timeout: 5))

        transport.abort(connection: connection, timeout: -1, connectionData: "[]")

        XCTAssertTrue(StubURLProtocol.waitForStop(pathSuffix: "/connect", timeout: 5), "The event stream stayed open after abort")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/abort") == true }, "A negative timeout must not call the server")
    }

    func testServerSentEventsAbortDoesNotReportAStartAfterwards() throws {
        let connection = makeConnection(url: "https://signalr.test/signalr/")
        connection.transportConnectTimeout = 0.5
        let transport = ServerSentEventsTransport()
        let noCallback = expectation(description: "start completion must not run after abort")
        noCallback.isInverted = true

        transport.start(connection: connection, connectionData: "[]") { _, _ in noCallback.fulfill() }
        XCTAssertTrue(StubURLProtocol.waitForRequest(pathSuffix: "/connect", timeout: 5))
        transport.abort(connection: connection, timeout: -1, connectionData: "[]")

        // Longer than transportConnectTimeout: the timeout must have been cancelled too.
        wait(for: [noCallback], timeout: 1.5)
    }

    // MARK: - Long polling

    func testLongPollingAbortCancelsTheOutstandingPoll() throws {
        let connection = makeConnection(url: "https://signalr.test/signalr/")
        let transport = LongPollingTransport()

        transport.start(connection: connection, connectionData: "[]", completionHandler: nil)
        XCTAssertTrue(StubURLProtocol.waitForRequest(pathSuffix: "/connect", timeout: 5), "The poll was not sent")

        transport.abort(connection: connection, timeout: -1, connectionData: "[]")

        XCTAssertTrue(StubURLProtocol.waitForStop(pathSuffix: "/connect", timeout: 5), "The poll stayed open after abort")
    }

    // MARK: - Abort request

    func testAbortSendsAPostWithTheConnectionParameters() throws {
        let connection = makeConnection(url: "https://signalr.test/signalr/")
        connection.connectionToken = "token"
        let transport = ServerSentEventsTransport()

        transport.abort(connection: connection, timeout: 2, connectionData: "[]")

        XCTAssertTrue(StubURLProtocol.waitForRequest(pathSuffix: "/abort", timeout: 5), "The abort request was never sent")
        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.path.hasSuffix("/abort") == true })
        XCTAssertEqual(request.httpMethod, "POST")
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertTrue(query.contains("transport=serverSentEvents"), query)
        XCTAssertTrue(query.contains("connectionToken=token"), query)
    }

    // MARK: - Connection

    func testConnectionBuildsURLRequestsWithHeadersAndTimeout() throws {
        let connection = makeConnection(url: "https://signalr.test/signalr/")
        connection.headers["X-Test"] = "1"

        let request = try XCTUnwrap(connection.getURLRequest(url: "https://signalr.test/signalr/connect", httpMethod: .get, encoding: URLEncoding.default, parameters: ["transport": "webSockets"], timeout: 12, headers: ["X-Extra": "2"]))

        XCTAssertEqual(request.url?.query, "transport=webSockets")
        XCTAssertEqual(request.timeoutInterval, 12)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Extra"), "2")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    // MARK: - Helpers

    private func makeConnection(url: String) -> Connection {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let connection = Connection(withUrl: url, queryString: ["sessionId": "test"], sessionManager: Session(configuration: configuration))
        connection.connectionToken = connection.connectionToken ?? "token"
        return connection
    }
}

// MARK: - Stub HTTP server

/// Answers SignalR requests without finishing `connect`/`poll` (like a live event stream or a held
/// long poll) and records which requests were started and which were stopped by the client.
final class StubURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var startedRequests: [URLRequest] = []
    private static var stoppedPaths: [String] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return startedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        startedRequests = []
        stoppedPaths = []
    }

    static func waitForRequest(pathSuffix: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { requests.contains { $0.url?.path.hasSuffix(pathSuffix) == true } }
    }

    static func waitForStop(pathSuffix: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            lock.lock(); defer { lock.unlock() }
            return stoppedPaths.contains { $0.hasSuffix(pathSuffix) }
        }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.startedRequests.append(request)
        Self.lock.unlock()

        let path = request.url?.path ?? ""
        let isHeld = path.hasSuffix("/connect") || path.hasSuffix("/poll") || path.hasSuffix("/reconnect")
        let contentType = path.hasSuffix("/connect") && request.url?.query?.contains("serverSentEvents") == true ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if isHeld {
            if contentType == "text/event-stream" {
                client?.urlProtocol(self, didLoad: Data("data: initialized\n\n".utf8))
            }
            return // Never finishes, like a live stream or a long poll the server holds.
        }

        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stoppedPaths.append(request.url?.path ?? "")
        Self.lock.unlock()
    }
}

// MARK: - Local TCP server

/// Accepts one TCP connection on 127.0.0.1 and records the first line of the HTTP request on it.
final class HandshakeRecordingServer {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "HandshakeRecordingServer")
    private let lock = NSLock()
    private var requestLine: String?
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
                self.lock.lock()
                self.requestLine = text.components(separatedBy: "\r\n").first
                self.lock.unlock()
            }
        }
        listener.start(queue: queue)
    }

    func waitForPort(timeout: TimeInterval) -> UInt16? {
        poll(timeout: timeout) {
            guard let port = self.listener.port?.rawValue, port != 0 else { return nil }
            return port
        }
    }

    func waitForRequestLine(timeout: TimeInterval) -> String? {
        poll(timeout: timeout) {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.requestLine
        }
    }

    func stop() {
        lock.lock(); let open = connections; lock.unlock()
        open.forEach { $0.cancel() }
        listener.cancel()
    }

    private func poll<T>(timeout: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = value() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return value()
    }
}
