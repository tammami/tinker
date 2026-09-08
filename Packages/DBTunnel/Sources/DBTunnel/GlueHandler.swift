import NIOCore

/// Pipes one channel into another in both directions, so a locally accepted socket and an
/// SSH `direct-tcpip` channel behave as one connection.
///
/// Flow control is explicit, as in NIOSSH's own reference glue: each channel reads only
/// while its partner is writable, and a partner that stops being writable stops the
/// reads until it drains. Without that, a slow local consumer lets pending writes grow
/// without bound while a large result streams in.
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
        // Reads are pulled by hand from the partner's writability, never automatic.
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        // Both ends start reading once both are up and writable.
        if partner?.context?.channel.isWritable ?? false { context.read() }
        partner?.readIfPartnerWritable()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // This side drained (or filled): the partner may resume (or must pause) reading.
        if context.channel.isWritable { partner?.readIfPartnerWritable() }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        // Only read when what arrives can be written on: the partner's buffer is the gate.
        if partner?.context?.channel.isWritable ?? true { context.read() }
    }

    /// Asks this channel to read, provided the partner can take what arrives.
    private func readIfPartnerWritable() {
        guard let context, partner?.context?.channel.isWritable ?? false else { return }
        context.read()
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
        // Keep reading while the partner stays writable; stop when it fills up and let
        // its writability change restart us.
        if partner?.context?.channel.isWritable ?? false { context.read() }
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
