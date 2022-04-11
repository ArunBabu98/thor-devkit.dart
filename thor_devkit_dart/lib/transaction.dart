import 'dart:typed_data';

import 'package:rlp/rlp.dart';
import 'package:thor_devkit_dart/crypto/address.dart';
import 'package:thor_devkit_dart/crypto/blake2b.dart';
import 'package:thor_devkit_dart/crypto/secp256k1.dart';
import 'package:thor_devkit_dart/crypto/thor_signature.dart';
import 'package:thor_devkit_dart/types/clause.dart';
import 'package:thor_devkit_dart/types/compact_fixed_blob_kind.dart';
import 'package:thor_devkit_dart/types/nullable_fixed_blob_kind.dart';
import 'package:thor_devkit_dart/types/numeric_kind.dart';
import 'package:thor_devkit_dart/types/reserved.dart';
import 'package:thor_devkit_dart/utils.dart';

class Transaction {
  static const int delegatedMask = 1;
  NumericKind chainTag = NumericKind(1);
  CompactFixedBlobKind blockRef = CompactFixedBlobKind(8);
  NumericKind expiration = NumericKind(4);
  late List<Clause> clauses;
  NumericKind gasPriceCoef = NumericKind(1);
  NumericKind gas = NumericKind(8);
  NullableFixedBlobKind dependsOn = NullableFixedBlobKind(32);
  NumericKind nonce = NumericKind(8);
  Reserved? reserved;

  Uint8List? signature;

  /// Construct a Transaction.
  /// @param chainTag eg. "1"
  /// @param blockRef eg. "0x00000000aabbccdd"
  /// @param expiration eg. "32"
  /// @param clauses See Clause.java
  /// @param gasPriceCoef eg. "128"
  /// @param gas eg. "21000"
  /// @param dependsOn eg. "0x..." as block ID, or null if not wish to depends on.
  /// @param nonce eg. "12345678", as a random positive number max width is 8 bytes.
  /// @param reserved See Reserved.java

  Transaction(
      String chainTag,
      String blockRef,
      String expiration,
      this.clauses,
      String gasPriceCoef,
      String gas,
      String? dependsOn, // can be null
      String nonce,
      Reserved? reserved // can be null
      ) {
    this.chainTag.setValueString(chainTag);
    this.blockRef.setValue(blockRef);
    this.expiration.setValueString(expiration);

    this.gasPriceCoef.setValueString(gasPriceCoef);
    this.gas.setValueString(gas);
    this.dependsOn.setValue(dependsOn);
    this.nonce.setValueString(nonce);
    if (reserved == null) {
      this.reserved = Reserved.getNullReserved();
    } else {
      this.reserved = reserved;
    }
  }

  /// Calculate the gas used by the data section.
  ///
  /// @param data Thre pure bytes of the data.

  static int calcDataGas(Uint8List data) {
    const int zGas = 4;
    const int nzGas = 68;

    int sum = 0;
    for (int i = 0; i < data.length; i++) {
      if (data[i] == 0) {
        sum += zGas;
      } else {
        sum += nzGas;
      }
    }
    return sum;
  }

  /// Calculate roughly the gas from a list of clauses.
  ///
  /// @param clauses A list of clauses.
  /// @return

  static int calcIntrinsicGas(List<Clause> clauses) {
    const int transactionGas = 5000;
    const int clauseGas = 16000;
    const int clauseContrctCreation = 48000;

    // Must pay a static fee even empty!
    if (clauses.isEmpty) {
      return transactionGas + clauseGas;
    }

    int sum = 0;
    sum += transactionGas;

    for (Clause c in clauses) {
      int clauseSum = 0;

      if (c.to.toBytes().isEmpty) {
        // contract creation
        clauseSum += clauseContrctCreation;
      } else {
        // or a normal clause
        clauseSum += clauseGas;
      }

      clauseSum += calcDataGas(c.data.toBytes());
      sum += clauseSum;
    }

    return sum;
  }

  /// Get the rough gas this tx will consume.
  /// @return

  int getIntrinsicGas() {
    return calcIntrinsicGas(clauses);
  }

  ///Determine if this is a delegated transaction (vip-191)

  bool isDelegated() {
    if (reserved == null) {
      return false;
    }
    if (reserved!.features == 0) {
      return false;
    }

    //TODO: make sure this is correct
    return reserved!.features == delegatedMask;
  }

  ///Check if the signature is valid.

  bool _isSignatureValid() {
    int expectedSignatureLength;
    if (isDelegated()) {
      expectedSignatureLength = 65 * 2;
    } else {
      expectedSignatureLength = 65;
    }

    if (signature == null) {
      return false;
    } else {
      return (signature!.length == expectedSignatureLength);
    }
  }

  ///Compute the hash result to be signed.
  /// @param delegateFor "0x..." the address to delegate for him or null.

  Uint8List getSigningHash(String? delegateFor) {
    // Get a unsigned Tx body as List
    List<dynamic> unsignedTxBody = packUnsignedTxBody();
    // RLP encode them to bytes.
    Uint8List buff = Rlp.encode(unsignedTxBody);
    // Hash it.
    Uint8List h = blake2b256([buff]);

    if (delegateFor != null) {
      if (!isAddress(delegateFor)) {
        throw Exception("delegateFor should be address type.");
      }
      return blake2b256([h, hexToBytes(delegateFor.substring(2))]);
    } else {
      return h;
    }
  }

  ///Pack the objects bytes in a fixed order.
  List<Object> packUnsignedTxBody() {
    // Prepare reserved.

    //FIXME: check if reserved can be null
    List<Uint8List> _reserved = reserved!.pack();
    // Prepare clauses.
    List<Object> _clauses = [];
    for (Clause c in clauses) {
      _clauses.add(c.pack());
    }
    // Prepare unsigned tx.
    List<Object> unsignedBody = [
      chainTag.toBytes(),
      blockRef.toBytes(),
      expiration.toBytes(),
      _clauses,
      gasPriceCoef.toBytes(),
      gas.toBytes(),
      dependsOn.toBytes(),
      nonce.toBytes(),
      _reserved
    ];

    return unsignedBody;
  }

  ///Get "origin" of the tx by public key bytes style.
  ///@return If can't decode just return null.

  Uint8List? getOriginAsPublicKey() {
    if (!_isSignatureValid()) {
      return null;
    }

    try {
      Uint8List h = getSigningHash(null);
      ThorSignature sig = ThorSignature.fromBytes(
          Uint8List.fromList(signature!.sublist(0, 65)));
      Uint8List pubKey = recover(h, sig);
      return pubKey;
    } catch (e) {
      return null;
    }
  }

  ///Get "origin" of the tx by string Address style.
  /// Notice: Address != public key.
  String? getOriginAsAddressString() {
    Uint8List? pubKey = getOriginAsPublicKey();
    return pubKey == null ? null : publicKeyToAddressString(pubKey);
  }

  /// Get "origin" of the tx by bytes Address style.
  /// Notice: Address != public key.

  Uint8List? getOriginAsAddressBytes() {
    Uint8List? pubKey = getOriginAsPublicKey();
    return pubKey == null ? null : publicKeyToAddressBytes(pubKey);
  }

  ///Get the delegator public key as bytes.

  Uint8List? getDelegator() {
    if (!isDelegated()) {
      return null;
    }

    if (!_isSignatureValid()) {
      return null;
    }

    String? origin = getOriginAsAddressString();
    if (origin == null) {
      return null;
    }

    try {
      Uint8List h = getSigningHash(origin);
      ThorSignature sig = ThorSignature.fromBytes(
          Uint8List.fromList(signature!.sublist(65, signature!.length)));
      return recover(h, sig);
    } catch (e) {
      return null;
    }
  }

  /// Get the delegator as Address type, in bytes.
  /// @return or null.

  Uint8List? getDeleagtorAsAddressBytes() {
    Uint8List? pubKey = getDelegator();
    return pubKey == null ? null : publicKeyToAddressBytes(pubKey);
  }

  /// Get the delegator as Address type, in string.
  /// @return or null.
  String? getDelegatorAsAddressString() {
    Uint8List? pubKey = getDelegator();
    return pubKey == null ? null : publicKeyToAddressString(pubKey);
  }

  ///Calculate Tx id (32 bytes).
  /// @return or null.

  Uint8List? getId() {
    if (!_isSignatureValid()) {
      return null;
    }
    try {
      Uint8List h = getSigningHash(null);
      ThorSignature sig = ThorSignature.fromBytes(
          Uint8List.fromList(signature!.sublist(0, 65)));
      Uint8List pubKey = recover(h, sig);
      Uint8List addressBytes = publicKeyToAddressBytes(pubKey);
      return blake2b256([h, addressBytes]);
    } catch (e) {
      return null;
    }
  }

  ///Get TX id as "0x..." = 2 chars 0x + 64 chars hex
  ///@return or null.

  String? getIdAsString() {
    Uint8List? b = getId();
    return b == null ? null : "0x" + bytesToHex(b);
  }

  ///Encode a tx into bytes.

  Uint8List encode() {
    List<Object> unsignedTxBody = packUnsignedTxBody();

    // Pack more: append the sig bytes at the end.
    if (signature != null) {
      unsignedTxBody.add(signature!);
    }

    // RLP encode the packed body.
    return Rlp.encode(unsignedTxBody);
  }
}
