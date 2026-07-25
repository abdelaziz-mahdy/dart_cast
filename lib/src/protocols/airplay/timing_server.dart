import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../utils/logger.dart';

/// A minimal UDP timing server for AirPlay 2 playback.
///
/// AirPlay 2 receivers negotiate a clock during RTSP `SETUP`. The sender
/// advertises `timingProtocol: "NTP"` together with the UDP port this server
/// is bound to, and the receiver then sends NTP-shaped timing requests to it.
/// A receiver that gets no answer may refuse to start playback.
///
/// This mirrors pyatv's `TimingServer`
/// (`pyatv/protocols/raop/protocols/__init__.py`): it does not attempt real
/// clock synchronisation, it just answers every request with the current host
/// time so the receiver's handshake completes.
///
/// The socket lives for the duration of one playback — [bind] before `SETUP`
/// and [close] when playback ends.
class AirPlayTimingServer {
  /// Size of an RTP timing packet, in bytes.
  ///
  /// Layout (all big-endian): `proto:u8, type:u8, seqno:u16, padding:u32,
  /// reftime_sec:u32, reftime_frac:u32, recvtime_sec:u32, recvtime_frac:u32,
  /// sendtime_sec:u32, sendtime_frac:u32`.
  static const int packetLength = 32;

  /// RTP payload type used for timing replies (`0x53 | 0x80`).
  static const int timingReplyType = 0xD3;

  /// Offset between the NTP epoch (1900) and the Unix epoch (1970), in seconds.
  static const int ntpEpochOffset = 0x83AA7E80;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  int _requestCount = 0;

  /// The UDP port this server is bound to, or 0 when not bound.
  int get port => _socket?.port ?? 0;

  /// Whether the server currently holds a bound socket.
  bool get isRunning => _socket != null;

  /// Number of timing requests answered so far. Useful for diagnostics and
  /// for hardware verification runs.
  int get requestCount => _requestCount;

  /// Binds the timing socket to an ephemeral UDP port.
  ///
  /// [address] defaults to all IPv4 interfaces so the receiver can reach it
  /// on whichever interface the control connection uses.
  Future<int> bind({InternetAddress? address}) async {
    if (_socket != null) return _socket!.port;

    final socket = await RawDatagramSocket.bind(
      address ?? InternetAddress.anyIPv4,
      0,
    );
    _socket = socket;
    _subscription = socket.listen(_onEvent);
    CastLogger.info('AirPlay timing server: listening on UDP ${socket.port}');
    return socket.port;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;

    final datagram = socket.receive();
    if (datagram == null) return;
    if (datagram.data.length < packetLength) {
      CastLogger.debug(
        'AirPlay timing server: ignoring short packet '
        '(${datagram.data.length}B)',
      );
      return;
    }

    final reply = buildReply(datagram.data);
    socket.send(reply, datagram.address, datagram.port);
    _requestCount++;
    CastLogger.debug(
      'AirPlay timing server: answered request $_requestCount from '
      '${datagram.address.address}:${datagram.port}',
    );
  }

  /// Builds the timing reply for an incoming [request] packet.
  ///
  /// The request's `sendtime` is echoed back as the reply's `reftime`, and the
  /// current host time is used for both `recvtime` and `sendtime`.
  ///
  /// Exposed for testing so the packet layout can be asserted without a live
  /// socket.
  static Uint8List buildReply(List<int> request, {int? nowMicroseconds}) {
    final req = ByteData.sublistView(Uint8List.fromList(request));
    final sendTimeSec = req.getUint32(24);
    final sendTimeFrac = req.getUint32(28);

    final (nowSec, nowFrac) = ntpNow(nowMicroseconds: nowMicroseconds);

    final reply = ByteData(packetLength);
    reply.setUint8(0, req.getUint8(0)); // echo the protocol byte
    reply.setUint8(1, timingReplyType);
    reply.setUint16(2, 7); // sequence number, as pyatv sends
    reply.setUint32(4, 0); // padding
    reply.setUint32(8, sendTimeSec); // reftime = request's sendtime
    reply.setUint32(12, sendTimeFrac);
    reply.setUint32(16, nowSec); // recvtime
    reply.setUint32(20, nowFrac);
    reply.setUint32(24, nowSec); // sendtime
    reply.setUint32(28, nowFrac);
    return reply.buffer.asUint8List();
  }

  /// Returns the current time as NTP `(seconds, fraction)`.
  ///
  /// [nowMicroseconds] overrides the clock for deterministic tests.
  static (int, int) ntpNow({int? nowMicroseconds}) {
    final micros = nowMicroseconds ?? DateTime.now().microsecondsSinceEpoch;
    final seconds = micros ~/ 1000000;
    final fraction = micros - seconds * 1000000;
    return (
      (seconds + ntpEpochOffset) & 0xFFFFFFFF,
      ((fraction << 32) ~/ 1000000) & 0xFFFFFFFF,
    );
  }

  /// Closes the timing socket. Safe to call more than once.
  Future<void> close() async {
    if (_socket == null) return;
    CastLogger.debug(
      'AirPlay timing server: closing UDP $port '
      '($_requestCount requests answered)',
    );
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }
}
