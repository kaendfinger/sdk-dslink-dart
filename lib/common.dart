library dslink.common;

import 'dart:async';
import 'dart:convert';
import 'requester.dart';
import 'responder.dart';

import 'package:quiver/core.dart';
import 'src/crypto/pk.dart';

part 'src/common/node.dart';
part 'src/common/table.dart';
part 'src/common/value.dart';
part 'src/common/connection_channel.dart';
part 'src/common/connection_handler.dart';

JsonUtf8Encoder jsonUtf8Encoder = new JsonUtf8Encoder();

List foldList(List a, List b) {
  return a..addAll(b);
}

abstract class DsConnection {
  DsConnectionChannel get requesterChannel;
  DsConnectionChannel get responderChannel;
  /// trigger when requester channel is Ready
  Future<DsConnectionChannel> get onRequesterReady;

  /// notify the connection channel need to send data
  void requireSend();
  /// close the connection
  void close();
}
abstract class DsServerConnection extends DsConnection {
  /// send a server command to client such as salt string, or allowed:true
  void addServerCommand(String key, Object value);
}
abstract class DsClientConnection extends DsConnection {

}
abstract class DsConnectionChannel {
  /// raw connection need to handle error and resending of data, so it can only send one map at a time
  /// a new getData function will always overwrite the previous one;
  /// requester and responder should handle the merging of methods
  void sendWhenReady(List getData());
  /// receive data from method stream
  Stream<List> get onReceive;

  /// whether the connection is ready to send and receive data
  bool get isReady;

  Future<DsConnectionChannel> get onDisconnected;
}



abstract class DsSession {
  DsRequester get requester;
  DsResponder get responder;
  
  DsSecretNonce get nonce;
  
  /// trigger when requester channel is Ready
  Future<DsRequester> get onRequesterReady;
}
abstract class DsServerSession extends DsSession {
  DsPublicKey get publicKey;
}
abstract class DsClientSession extends DsSession {
  DsPrivateKey get privateKey;
  /// shortPolling is only valid in http mode
  updateSalt(String salt, [bool shortPolling = false]);
}





class DsStreamStatus {
  static const String initialize = 'initialize';
  static const String open = 'open';
  static const String closed = 'closed';
}

class DsErrorPhase {
  static const String request = 'request';
  static const String response = 'response';
}

class DsError {
  /// type of error
  String type;
  String detail;
  String msg;
  String path;
  String phase;

  DsError(this.msg, {this.detail, this.type, this.path, this.phase: DsErrorPhase.response});

  Map serialize() {
    Map rslt = {
      'msg': msg
    };
    if (type != null) {
      rslt['type'] = type;
    }
    if (path != null) {
      rslt['path'] = path;
    }
    if (phase == DsErrorPhase.request) {
      rslt['phase'] = DsErrorPhase.request;
    }
    if (detail != null) {
      rslt['detail'] = detail;
    }
    return rslt;
  }
}
