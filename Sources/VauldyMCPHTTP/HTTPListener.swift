import Foundation
import VauldyOAuth
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

/// Fixed loopback bind: a separately configured TLS proxy publishes only OAuth and /mcp.
actor HTTPListener {
    let router: HTTPRouter
    let port: Int
    private var channel: Channel?
    init(router: HTTPRouter, port: Int) { self.router = router; self.port = port }
    func stop() async { try? await channel?.close(); await router.stop() }
    func run() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let admission = Admission()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap { channel.pipeline.addHandler(RequestHandler(router: self.router, admission: admission)) }
                }
                .bind(host: "127.0.0.1", port: port).get()
            self.channel = channel
            FileHandle.standardError.write(Data("Vauldy OAuth: listening-on-loopback\n".utf8))
            try await channel.closeFuture.get()
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
private final class Admission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard active < 64 else { return false }; active += 1; return true }
    func release() { lock.lock(); active -= 1; lock.unlock() }
}
private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let router: HTTPRouter
    let admission: Admission
    var admitted = false
    var head: HTTPRequestHead?
    var body = Data()
    var processing = false
    var task: Task<Void, Never>?
    var timeout: Scheduled<Void>?
    init(router: HTTPRouter, admission: Admission) { self.router = router; self.admission = admission }
    func channelActive(context: ChannelHandlerContext) {
        admitted = admission.acquire()
        guard admitted else { context.close(promise: nil); return }
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(40)) { channel.close(promise: nil) }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel(); task?.cancel()
        if admitted { admission.release(); admitted = false }
        context.fireChannelInactive()
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !processing else { context.close(promise: nil); return }
        switch unwrapInboundIn(data) {
        case .head(let next):
            guard head == nil, next.uri.utf8.count <= 8192, next.headers.count <= 64,
                  next.headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16384,
                  next.headers["content-length"].first.flatMap(Int.init) ?? 0 <= 65536 else { context.close(promise: nil); return }
            var names = Set<String>()
            for (name, _) in next.headers {
                let key = name.lowercased()
                guard names.insert(key).inserted else { context.close(promise: nil); return }
            }
            head = next
        case .body(let buffer):
            guard head != nil, body.count + buffer.readableBytes <= 65536 else { context.close(promise: nil); return }
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let head else { context.close(promise: nil); return }
            processing = true
            let request = OAuthWebRequest(method: head.method.rawValue, target: head.uri,
                headers: Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name.lowercased(), $0.value) }), body: body)
            let channel = context.channel
            task = Task { [router] in
                let response = await router.handle(request)
                guard !Task.isCancelled else { return }
                try? await channel.eventLoop.submit {
                    var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
                    headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
                    headers.replaceOrAdd(name: "Connection", value: "close")
                    channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: response.status), headers: headers)), promise: nil)
                    if !response.body.isEmpty {
                        var buffer = channel.allocator.buffer(capacity: response.body.count); buffer.writeBytes(response.body)
                        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                    }
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
                }.get()
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
