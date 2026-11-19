import 'dart:convert';
import 'dart:typed_data';
import 'package:pinenacl/x25519.dart';
import 'package:pinenacl/api.dart';

// Fixed vectors — must match the Node tweetnacl counterpart byte-for-byte.
const secretKeyHex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const hostPubHex =
    'd91b57e1a5b3c1d2e4f6a7b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192';
const nonceHex = '000102030405060708090a0b0c0d0e0f1011121314151617';
const plaintext = 'pong';

Uint8List fromHex(String h) => Uint8List.fromList(List.generate(
    h.length ~/ 2, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)));

String hex(Uint8List b) =>
    b.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final sk = PrivateKey(fromHex(secretKeyHex));
  final hostPub = PublicKey(fromHex(hostPubHex));
  final box = Box(myPrivateKey: sk, theirPublicKey: hostPub);
  print('sharedKey=${hex(box.sharedKey.asTypedList)}');

  final nonce = fromHex(nonceHex);
  final enc = box.encrypt(Uint8List.fromList(utf8.encode(plaintext)),
      nonce: nonce);
  final bundle = enc.asTypedList; // nonce(24) + ciphertext
  print('ciphertext=${hex(bundle)}');
  print('bundleLen=${bundle.length}');

  final plain = box.decrypt(EncryptedMessage.fromList(Uint8List.fromList(bundle)));
  print('roundTrip=${utf8.decode(plain)}');

  // Tamper: flip one ciphertext byte, decrypt must fail.
  final tampered = Uint8List.fromList(bundle);
  tampered[tampered.length - 1] ^= 0xff;
  String? tamperResult;
  try {
    final t = box.decrypt(EncryptedMessage.fromList(tampered));
    tamperResult = utf8.decode(t);
  } catch (_) {
    tamperResult = 'FAILED_AS_EXPECTED';
  }
  print('tamper=$tamperResult');
}
