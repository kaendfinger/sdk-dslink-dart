library dslink.http.websocket;

import "dart:async";
import "dart:io";

import "../../common.dart";
import "../../utils.dart";

import "package:logging/logging.dart";

class WebSocketConnection extends Connection {
  PassiveChannel _responderChannel;

  ConnectionChannel get responderChannel => _responderChannel;

  PassiveChannel _requesterChannel;

  ConnectionChannel get requesterChannel => _requesterChannel;

  Completer<ConnectionChannel> onRequestReadyCompleter = new Completer<ConnectionChannel>();

  Future<ConnectionChannel> get onRequesterReady => onRequestReadyCompleter.future;

  Completer<bool> _onDisconnectedCompleter = new Completer<bool>();

  Future<bool> get onDisconnected => _onDisconnectedCompleter.future;

  final ClientLink clientLink;

  final WebSocket socket;

  bool _onDoneHandled = false;

  /// clientLink is not needed when websocket works in server link
  WebSocketConnection(this.socket,
      {this.clientLink, bool enableTimeout: false, bool enableAck: true, DsCodec useCodec}) {
    if (useCodec != null) {
      codec = useCodec;
    }
    _responderChannel = new PassiveChannel(this, true);
    _requesterChannel = new PassiveChannel(this, true);
    socket.listen(
        onData,
        onDone: _onDone,
        onError: (err) => logger.warning(
            formatLogMessage('Error listening to socket'), err));
    socket.add(codec.blankData);
    if (!enableAck) {
      nextMsgId = -1;
    }

    if (enableTimeout) {
      pingTimer = new Timer.periodic(const Duration(seconds: 20), onPingTimer);
    }
    // TODO(rinick): when it's used in client link, wait for the server to send {allowed} before complete this
  }

  Timer pingTimer;

  /// set to true when data is sent, reset the flag every 20 seconds
  /// since the previous ping message will cause the next 20 seoncd to have a message
  /// max interval between 2 ping messages is 40 seconds
  bool _dataSent = false;

  /// add this count every 20 seconds, set to 0 when receiving data
  /// when the count is 3, disconnect the link (>=60 seconds)
  int _dataReceiveCount = 0;

  static bool throughputEnabled = false;

  static int dataIn = 0;
  static int messageIn = 0;
  static int dataOut = 0;
  static int messageOut = 0;
  static int frameIn = 0;
  static int frameOut = 0;

  void onPingTimer(Timer t) {
    if (_dataReceiveCount >= 3) {
      logger.finest('close stale connection');
      this.close();
      return;
    }

    _dataReceiveCount++;

    if (_dataSent) {
      _dataSent = false;
      return;
    }
    this.addConnCommand(null, null);
  }

  void requireSend() {
    if (!_sending) {
      _sending = true;
      DsTimer.callLater(_send);
    }
  }

  /// special server command that need to be merged into message
  /// now only 2 possible value, salt, allowed
  Map _serverCommand;

  /// add server command, will be called only when used as server connection
  void addConnCommand(String key, Object value) {
    if (_serverCommand == null) {
      _serverCommand = {};
    }
    if (key != null) {
      _serverCommand[key] = value;
    }

    requireSend();
  }

  void onData(dynamic data) {
    if (throughputEnabled) {
      frameIn++;
    }

    if (_onDisconnectedCompleter.isCompleted) {
      return;
    }
    if (!onRequestReadyCompleter.isCompleted) {
      onRequestReadyCompleter.complete(_requesterChannel);
    }
    _dataReceiveCount = 0;
    Map m;
    if (data is List<int>) {
      try {
        m = codec.decodeBinaryFrame(data as List<int>);
        if (logger.isLoggable(Level.FINEST)) {
          logger.finest(formatLogMessage("receive: ${m}"));
        }
      } catch (err, stack) {
        logger.fine(
          formatLogMessage("Failed to decode binary data in WebSocket Connection"),
          err,
          stack
        );
        close();
        return;
      }

      if (throughputEnabled) {
        dataIn += data.length;
      }

      data = null;

      bool needAck = false;
      if (m["responses"] is List && (m["responses"] as List).length > 0) {
        needAck = true;
        // send responses to requester channel
        _requesterChannel.onReceiveController.add(m["responses"]);

        if (throughputEnabled) {
          messageIn += (m["responses"] as List).length;
        }
      }

      if (m["requests"] is List && (m["requests"] as List).length > 0) {
        needAck = true;
        // send requests to responder channel
        _responderChannel.onReceiveController.add(m["requests"]);

        if (throughputEnabled) {
          messageIn += (m["requests"] as List).length;
        }
      }

      if (m["ack"] is int) {
        ack(m["ack"]);
      }

      if (needAck) {
        Object msgId = m["msg"];
        if (msgId != null) {
          addConnCommand("ack", msgId);
        }
      }
    } else if (data is String) {
      try {
        m = codec.decodeStringFrame(data);
        if (logger.isLoggable(Level.FINEST)) {
          logger.finest(formatLogMessage("receive: ${m}"));
        }
      } catch (err, stack) {
        logger.severe(
          formatLogMessage("Failed to decode string data from WebSocket Connection"),
          err,
          stack
        );
        close();
        return;
      }

      if (throughputEnabled) {
        dataIn += data.length;
      }

      if (m["salt"] is String && clientLink != null) {
        clientLink.updateSalt(m["salt"]);
      }

      bool needAck = false;
      if (m["responses"] is List && (m["responses"] as List).length > 0) {
        needAck = true;
        // send responses to requester channel
        _requesterChannel.onReceiveController.add(m["responses"]);
        if (throughputEnabled) {
          for (Map resp in m["responses"]) {
            if (resp["updates"] is List) {
              int len = resp["updates"].length;
              if (len > 0) {
                messageIn += len;
              } else {
                messageIn += 1;
              }
            } else {
              messageIn += 1;
            }
          }
        }
      }

      if (m["requests"] is List && (m["requests"] as List).length > 0) {
        needAck = true;
        // send requests to responder channel
        _responderChannel.onReceiveController.add(m["requests"]);
        if (throughputEnabled) {
          messageIn += m["requests"].length;
        }
      }
      if (m["ack"] is int) {
        ack(m["ack"]);
      }
      if (needAck) {
        Object msgId = m["msg"];
        if (msgId != null) {
          addConnCommand("ack", msgId);
        }
      }
    }
  }

  /// when nextMsgId = -1, ack is disabled
  int nextMsgId = 1;
  bool _sending = false;

  void _send() {
    _sending = false;
    bool needSend = false;
    Map m;
    if (_serverCommand != null) {
      m = _serverCommand;
      _serverCommand = null;
      needSend = true;
    } else {
      m = {};
    }
    var pendingAck = <ConnectionProcessor>[];
    int ts = (new DateTime.now()).millisecondsSinceEpoch;
    ProcessorResult rslt = _responderChannel.getSendingData(ts, nextMsgId);
    if (rslt != null) {
      if (rslt.messages.length > 0) {
        m["responses"] = rslt.messages;
        needSend = true;
        if (throughputEnabled) {
          for (Map resp in rslt.messages) {
            if (resp["updates"] is List) {
              int len = resp["updates"].length;
              if (len > 0) {
                messageOut += len;
              } else {
                messageOut += 1;
              }
            } else {
              messageOut += 1;
            }
          }
        }
      }
      if (rslt.processors.length > 0) {
        pendingAck.addAll(rslt.processors);
      }
    }
    rslt = _requesterChannel.getSendingData(ts, nextMsgId);
    if (rslt != null) {
      if (rslt.messages.length > 0) {
        m["requests"] = rslt.messages;
        needSend = true;
        if (throughputEnabled) {
          messageOut += rslt.messages.length;
        }
      }
      if (rslt.processors.length > 0) {
        pendingAck.addAll(rslt.processors);
      }
    }

    if (needSend) {
      if (nextMsgId != -1) {
        if (pendingAck.length > 0) {
          pendingAcks.add(new ConnectionAckGroup(nextMsgId, ts, pendingAck));
        }
        m["msg"] = nextMsgId;
        if (nextMsgId < 0x7FFFFFFF) {
          ++nextMsgId;
        } else {
          nextMsgId = 1;
        }
      }
      addData(m);
      _dataSent = true;

      if (throughputEnabled) {
        frameOut++;
      }
    }
  }

  void addData(Map m) {
    if (socket.readyState != WebSocket.OPEN || _onDoneHandled) {
       return;
    }
    
    Object encoded = codec.encodeFrame(m);

    if (logger.isLoggable(Level.FINEST)) {
      logger.finest(formatLogMessage("send: $m"));
    }

    if (throughputEnabled) {
      if (encoded is String) {
        dataOut += encoded.length;
      } else if (encoded is List<int>) {
        dataOut += encoded.length;
      } else {
        logger.warning(formatLogMessage("invalid data frame"));
      }
    }
    try {
      socket.add(encoded);
    } catch (e) {
      logger.severe(formatLogMessage('Error writing to socket'), e);
      close();
    }
  }

  bool printDisconnectedMessage = true;

  void _onDone() {
    if (_onDoneHandled) {
      return;
    }

    _onDoneHandled = true;

    if (printDisconnectedMessage) {
      logger.info(formatLogMessage("Disconnected"));
    }

    if (!_requesterChannel.onReceiveController.isClosed) {
      _requesterChannel.onReceiveController.close();
    }

    if (!_requesterChannel.onDisconnectController.isCompleted) {
      _requesterChannel.onDisconnectController.complete(_requesterChannel);
    }

    if (!_responderChannel.onReceiveController.isClosed) {
      _responderChannel.onReceiveController.close();
    }

    if (!_responderChannel.onDisconnectController.isCompleted) {
      _responderChannel.onDisconnectController.complete(_responderChannel);
    }

    if (!_onDisconnectedCompleter.isCompleted) {
      _onDisconnectedCompleter.complete(false);
    }

    if (pingTimer != null) {
      pingTimer.cancel();
    }
  }

  String formatLogMessage(String msg) {
    if (clientLink != null) {
      return clientLink.formatLogMessage(msg);
    }

    if (logName != null) {
      return "[${logName}] ${msg}";
    }
    return msg;
  }

  String logName;

  void close() {
    if (socket.readyState == WebSocket.OPEN ||
        socket.readyState == WebSocket.CONNECTING) {
      socket.close();
    }
    _onDone();
  }
}
