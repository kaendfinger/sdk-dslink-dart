library dslink.http.websocket;

import "dart:async";
import "dart:io";

import "../../common.dart";
import "../../utils.dart";

import "dart:typed_data";
import 'package:logging/logging.dart';

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

    _queue = new DSPacketQueue(
      DSPacketQueueMode.store,
      handleNewPacketStore,
      handleAckPacket,
      handleMsgPacket
    );

    socket.add(<int>[]);
    socket.listen(onData, onDone: _onDone);
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
      this.close();
      return;
    }

    _dataReceiveCount++;

    if (_dataSent) {
      _dataSent = false;
      return;
    }
    addConnCommand(null, null);
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

  DSPacketReader _reader = new DSPacketReader();
  DSPacketQueue _queue;

  void handleNewPacketStore(DSPacketStore store) {
    store.handler = handlePacketDelivery;
  }

  void handlePacketDelivery(DSPacketStore store, DSNormalPacket _) {
    if (store.isComplete) {
      var pkt = store.formNewPacket();
      if (pkt is DSResponsePacket) {
        _requesterChannel.onReceiveController.add(pkt);
      } else if (pkt is DSRequestPacket) {
        _responderChannel.onReceiveController.add(pkt);
      }
      store.drop();
    }
  }

  void onData(dynamic data) {
    frameIn++;
    if (_onDisconnectedCompleter.isCompleted) {
      return;
    }
    if (!onRequestReadyCompleter.isCompleted) {
      onRequestReadyCompleter.complete(_requesterChannel);
    }
    _dataReceiveCount = 0;

    if (data is List<int>) {
      if (data.length == 0) {
        return;
      }

      List<DSPacket> packets = _reader.read(data);

      if (logger.isLoggable(Level.FINEST)) {
        for (DSPacket pkt in packets) {
          logger.finest(formatLogMessage("Receive: ${pkt}"));
        }
      }

      _queue.handleAll(packets);
    }
  }

  void handleAckPacket(DSAckPacket pkt) {
    ack(pkt.ackId);
  }

  void handleMsgPacket(DSMsgPacket pkt) {
    var id = pkt.ackId;
    if (id != null) {
      addConnCommand("ack", id);
    }
  }

  /// when nextMsgId = -1, ack is disabled
  int nextMsgId = 1;
  bool _sending = false;

  DSPacketWriter _writer = new DSPacketWriter();

  void _send() {
    _sending = false;
    bool needSend = false;

    var pkts = <DSPacket>[];

    if (_serverCommand != null) {
      if (_serverCommand["ack"] is int) {
        var pkt = new DSAckPacket();
        pkt.ackId = _serverCommand["ack"];
        _serverCommand = null;
        if (logger.isLoggable(Level.FINEST)) {
          logger.finest(formatLogMessage("Send: ${pkt}"));
        }
        pkt.writeTo(_writer);
        addData(_writer.done());
        requireSend();
        return;
      } else {
        needSend = true;
        _serverCommand = null;
      }
    }

    var pendingAck = <ConnectionProcessor>[];
    int ts = (new DateTime.now()).millisecondsSinceEpoch;
    ProcessorResult rslt = _responderChannel.getSendingData(ts, nextMsgId);
    if (rslt != null) {
      if (rslt.messages.length > 0) {
        needSend = true;

        for (DSPacket pkt in rslt.messages) {
          if (pkt is DSNormalPacket && pkt.isLargePayload()) {
            pkts.addAll(pkt.split());
          } else {
            pkts.add(pkt);
          }

          if (throughputEnabled) {
            messageOut += 1;
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
        needSend = true;
        if (throughputEnabled) {
          messageOut += rslt.messages.length;
        }

        for (DSPacket pkt in rslt.messages) {
          if (pkt is DSNormalPacket && pkt.isLargePayload()) {
            pkts.addAll(pkt.split());
          } else {
            pkts.add(pkt);
          }
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

        var pkt = new DSMsgPacket();
        pkt.ackId = nextMsgId;

        if (nextMsgId < 0x7FFFFFFF) {
          ++nextMsgId;
        } else {
          nextMsgId = 1;
        }

        // Consider where the msg packet is, adding it last is best
        // if we hit a frame limit.
        pkts.add(pkt);
      }

      bool needsWrite = true;

      for (var pkt in pkts) {
        needsWrite = true;

        if (logger.isLoggable(Level.FINEST)) {
          logger.finest(formatLogMessage("Send: ${pkt}"));
        }

        pkt.writeTo(_writer);

        if (_writer.currentLength > 76800) { // 75KB frame limit
          logger.finer("Frame limit hit, sending packets.");
          addData(_writer.done());
          needsWrite = false;
          frameOut++;
        }
      }

      if (needsWrite) {
        addData(_writer.done());
        frameOut++;
      }

      _dataSent = true;
    }
  }

  void addData(Uint8List data) {
    new Future(() {
      socket.add(data);
    });
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
