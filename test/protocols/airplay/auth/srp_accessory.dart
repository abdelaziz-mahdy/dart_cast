import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The accessory (receiver) side of HAP SRP-6a, written independently of
/// `HapSrp` so mocks can check the controller's M1 and answer with a real M2.
///
/// Follows HomeKitADK `PAL/Crypto/MbedTLS/HAPMbedTLS.c`:
/// - `HAP_srp_proof_m1`: H(H(N) xor H(g) | H(user) | salt | A | B | K) with
///   leading zero bytes stripped from A and B, `g` hashed as one byte.
/// - `HAP_srp_session_key`: K = H(S) with leading zero bytes stripped.
/// - `HAP_srp_proof_m2`: H(A | M1 | K) with A at its full 384 bytes.
class SrpAccessory {
  static final BigInt n = BigInt.parse(
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1'
    '29024E088A67CC74020BBEA63B139B22514A08798E3404DD'
    'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245'
    'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
    'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D'
    'C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F'
    '83655D23DCA3AD961C62F356208552BB9ED529077096966D'
    '670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B'
    'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9'
    'DE2BCBF6955817183995497CEA956AE515D2261898FA0510'
    '15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64'
    'ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7'
    'ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B'
    'F12FFA06D98A0864D87602733EC86A64521F2B18177B200C'
    'BBE117577A615D6C770988C0BAD946E208E24FA074E5AB31'
    '43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF',
    radix: 16,
  );
  static final BigInt g = BigInt.from(5);

  final String pin;
  final Uint8List salt;
  final BigInt _b;
  late final BigInt _v;
  late final BigInt _publicB;

  SrpAccessory._(this.pin, this.salt, this._b);

  /// Creates an accessory for [pin] with a deterministic salt and secret.
  static Future<SrpAccessory> create({
    String pin = '3939',
    int seed = 7,
  }) async {
    final random = Random(seed);
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final bBytes = List<int>.generate(32, (_) => random.nextInt(256));
    final accessory = SrpAccessory._(pin, salt, _toBigInt(bBytes));
    await accessory._init();
    return accessory;
  }

  Future<void> _init() async {
    final x = _toBigInt(
      await _h([...salt, ...await _h(utf8.encode('Pair-Setup:$pin'))]),
    );
    _v = g.modPow(x, n);
    final k = _toBigInt(await _h([..._pad(n), ..._pad(g)]));
    _publicB = (k * _v + g.modPow(_b, n)) % n;
  }

  /// B, padded to 384 bytes, for the M2 `PublicKey` TLV.
  Uint8List get publicKey => _pad(_publicB);

  /// Checks the controller's [m1] for public key [aBytes].
  ///
  /// Returns M2 when M1 is right, or `null` when it is wrong (the accessory
  /// would answer with `kTLVError_Authentication`).
  Future<Uint8List?> verifyM1(List<int> aBytes, List<int> m1) async {
    final a = _toBigInt(aBytes);
    final u = _toBigInt(await _h([..._pad(a), ..._pad(_publicB)]));
    final s = (a * _v.modPow(u, n)).modPow(_b, n);
    final key = await _h(_strip(_pad(s)));

    final hN = await _h(_strip(_pad(n)));
    final hG = await _h([5]);
    final xor = List<int>.generate(64, (i) => hN[i] ^ hG[i]);
    final expectedM1 = await _h([
      ...xor,
      ...await _h(utf8.encode('Pair-Setup')),
      ...salt,
      ..._strip(_pad(a)),
      ..._strip(_pad(_publicB)),
      ...key,
    ]);
    if (!_equal(expectedM1, m1)) return null;

    return Uint8List.fromList(await _h([..._pad(a), ...m1, ...key]));
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<List<int>> _h(List<int> data) async =>
      (await Sha512().hash(data)).bytes;

  static BigInt _toBigInt(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }

  static Uint8List _pad(BigInt value) {
    final out = Uint8List(384);
    var v = value;
    for (var i = 383; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v >>= 8;
    }
    return out;
  }

  static List<int> _strip(List<int> bytes) {
    var i = 0;
    while (i < bytes.length - 1 && bytes[i] == 0) {
      i++;
    }
    return bytes.sublist(i);
  }
}
