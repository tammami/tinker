import NIOCore

/// Pipes one channel into another in both directions, so a locally accepted socket and an
/// SSH `direct-tcpip` channel behave as one connection.
///
/// Flow control comes from the layers underneath: the SSH channel window bounds what the
/// server may send ahead, and TCP bounds the local side. The handler therefore forwards
/// eagerly and never withholds a read, which is what keeps a forward from stalling when
/// one side is quiet.
///
/// Marked `@unchecked Sendable` because a pair is confined to one event loop: the forward
/// binds the accepted socket to the SSH connection's loop, so both handlers and both
/// channels are only ever touched there.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?

    private init() {}

    /// Creates a pair of handlers, each forwarding into the other's channel.
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.forward(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.forwardFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        // One end closing must close the other, or the peer waits forever.
        partner?.closeChannel()
        partner = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        partner?.closeChannel()
        partner = nil
        context.close(promise: nil)
    }

    private func forward(_ buffer: ByteBuffer) {
        context?.write(wrapOutboundOut(buffer), promise: nil)
    }

    private func forwardFlush() {
        context?.flush()
    }

    private func closeChannel() {
        context?.close(promise: nil)
    }
}
