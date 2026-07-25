import 'dart:io';
import 'dart:typed_data';

import '../../../utils/logger.dart';
import 'airplay_auth.dart';
import 'hap_srp.dart';
import 'socket_http.dart';
import 'tlv8.dart';

/// AirPlay 2 *transient* pairing (`X-Apple-HKP: 4`).
///
/// Transient pairing runs only the first four messages of the HAP pair-setup
/// flow. There is no PIN for the user to read off the screen — the password is
/// the fixed string `3939` — and nothing is persisted afterwards: the SRP
/// shared secret is used to key the encrypted channel for this connection and
/// then discarded.
///
/// Receivers advertising bit 43 (`SupportsSystemPairing`) or bit 48
/// (`SupportsCoreUtilsPairingAndEncryption`) expect this flow. Both the Roku
/// Express and the TCL Google TV observed on the developer's network set both
/// bits, and neither will ever display a PIN for the `X-Apple-HKP: 3` flow the
/// package used to be limited to.
///
/// Reference: `pyatv/protocols/airplay/auth/hap_transient.py`.
class AirPlayTransientPairing {
  /// The fixed SRP password used by transient pairing.
  static const String transientPin = '3939';

  /// `Flags` TLV value requesting transient pairing.
  static const int transientPairingFlag = 0x10;

  /// Headers pyatv sends on every transient pairing request.
  static const Map<String, String> pairingHeaders = {
    'User-Agent': 'AirPlay/320.20',
    'Connection': 'keep-alive',
    'X-Apple-HKP': '4',
    'Content-Type': 'application/octet-stream',
  };

  final SocketHttpChannel _channel;
  final HapSrp _srp;

  AirPlayTransientPairing._(this._channel, {HapSrp? srp})
    : _srp = srp ?? HapSrp();

  /// Creates a transient pairing procedure that runs over an existing
  /// [socket].
  ///
  /// The socket is not closed here — after [execute] succeeds the caller
  /// promotes the very same connection to an encrypted HAP session, which is
  /// mandatory because the receiver binds the pairing to this TCP connection.
  ///
  /// Pass [dataStream] when the socket's stream is shared through a broadcast
  /// wrapper.
  factory AirPlayTransientPairing.withSocket(
    Socket socket, {
    required String host,
    required int port,
    Stream<Uint8List>? dataStream,
    HapSrp? srp,
  }) {
    return AirPlayTransientPairing._(
      SocketHttpChannel(socket, host: host, port: port, dataStream: dataStream),
      srp: srp,
    );
  }

  /// Runs M1–M4 and returns the SRP shared secret `K`.
  ///
  /// Feed the result to `deriveHapSessionKeys` to key the encrypted channel.
  ///
  /// Throws [AirPlayAuthException] if the receiver rejects the exchange.
  Future<Uint8List> execute() async {
    CastLogger.info('AirPlay auth: transient pairing (X-Apple-HKP 4)');

    // pyatv pokes /pair-pin-start first. Receivers that need no PIN answer
    // with an error or nothing useful, so the result is deliberately ignored.
    try {
      await _channel.post(
        '/pair-pin-start',
        headers: pairingHeaders,
        timeout: const Duration(seconds: 5),
      );
    } on SocketHttpException catch (e) {
      CastLogger.debug('AirPlay auth: pair-pin-start ignored ($e)');
    }

    // -- M1: request transient pairing --
    final clientPublicKey = await _srp.step1();
    final m1 = Tlv8.encode([
      (Tlv8.tagMethod, [0x00]),
      (Tlv8.tagSeqNo, [0x01]),
      (Tlv8.tagFlags, [transientPairingFlag]),
    ]);

    final m2 = _decode(await _post(m1), 'M2');

    final salt = m2[Tlv8.tagSalt];
    final serverPublicKey = m2[Tlv8.tagPublicKey];
    if (salt == null || serverPublicKey == null) {
      throw AirPlayAuthException(
        'transient pairing M2 is missing salt or public key — '
        'the receiver may not support transient pairing',
      );
    }
    CastLogger.info(
      'AirPlay auth: transient M2 (salt ${salt.length}B, '
      'pubkey ${serverPublicKey.length}B)',
    );

    // -- M3: SRP proof against the fixed PIN --
    final proof = await _srp.step2(
      serverPublicKey: Uint8List.fromList(serverPublicKey),
      salt: Uint8List.fromList(salt),
      pin: transientPin,
    );

    final m3 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x03]),
      (Tlv8.tagPublicKey, clientPublicKey),
      (Tlv8.tagProof, proof),
    ]);

    _decode(await _post(m3), 'M4');

    final sharedKey = _srp.sharedKey;
    if (sharedKey == null) {
      throw AirPlayAuthException(
        'transient pairing completed without an SRP shared secret',
      );
    }

    // Transient pairing ends at M4 — there is no M5/M6 and nothing to store.
    CastLogger.info(
      'AirPlay auth: transient pairing complete (no credentials)',
    );
    return sharedKey;
  }

  Future<Uint8List> _post(Uint8List body) async {
    final response = await _channel.post(
      '/pair-setup',
      headers: pairingHeaders,
      body: body,
    );
    if (response.statusCode != 200) {
      throw AirPlayAuthException(
        'transient pair-setup failed with HTTP ${response.statusCode}',
      );
    }
    return response.body;
  }

  Map<int, List<int>> _decode(Uint8List body, String step) {
    final Map<int, List<int>> tlv;
    try {
      tlv = Tlv8.decode(body);
    } on FormatException catch (e) {
      throw AirPlayAuthException(
        'transient pairing $step is not valid TLV8: $e',
      );
    }
    final error = tlv[Tlv8.tagError];
    if (error != null && error.isNotEmpty) {
      throw AirPlayAuthException(
        'transient pairing $step error: code ${error.first}',
      );
    }
    return tlv;
  }

  /// Stops reading from the socket so it can be handed to the HAP session.
  Future<void> releaseSocket() => _channel.release();
}
