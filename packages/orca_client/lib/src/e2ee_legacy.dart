import 'dart:convert';
import 'dart:typed_data';
import 'package:pinenacl/x25519.dart';
import 'package:pinenacl/api.dart';

/// Legacy frames use standard base64 of nonce + authenticated ciphertext.
class LegacyE2EEChannel {
  final PrivateKey _clientSecretKey;
  Box? _box;

  LegacyE2EEChannel({required PrivateKey clientSecretKey})
      : _clientSecretKey = clientSecretKey;

  bool get isReady => _box != null;

  /// Derive the shared key from the host's base64url public key (from the offer).
  void acceptReady(String hostPublicKeyB64Url) {
    final hostPub = PublicKey(_decode(hostPublicKeyB64Url));
    _box = Box(myPrivateKey: _clientSecretKey, theirPublicKey: hostPub);
  }

  /// Seal a plaintext string into a base64 transport frame.
  String seal(String plaintext) {
    final box = _box ?? (throw StateError('channel not ready'));
    final nonce = PineNaClUtils.randombytes(EncryptedMessage.nonceLength);
    final enc =
        box.encrypt(Uint8List.fromList(utf8.encode(plaintext)), nonce: nonce);
    return _encode(enc.asTypedList);
  }

  /// Accept standard or URL-safe base64; null on malformed or unauthenticated frames.
  String? open(String frame) {
    final box = _box;
    if (box == null) return null;
    try {
      final bundle = _decode(frame);
      if (bundle.length < EncryptedMessage.nonceLength + 16) return null;
      final plain =
          box.decrypt(EncryptedMessage.fromList(Uint8List.fromList(bundle)));
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }
}

/// Encode bytes to standard base64 (Node `Buffer.toString('base64')`).
String _encode(Uint8List bytes) => base64.encode(bytes);

/// Decode a standard base64 string, restoring any missing padding.
Uint8List _decode(String s) => base64.decode(base64.normalize(s.trim()));

/// Generate a client NaCl box secret key.
PrivateKey generateClientSecretKey() => PrivateKey.generate();

/// The client public key, base64url-encoded for the e2ee_hello frame.
String clientPublicKeyB64Url(PrivateKey sk) =>
    base64Url.encode(sk.publicKey.asTypedList).replaceAll('=', '');

/// Build a channel from a secret key (public key is sent in the hello).
LegacyE2EEChannel channelFromSecretKey(PrivateKey sk) =>
    LegacyE2EEChannel(clientSecretKey: sk);
