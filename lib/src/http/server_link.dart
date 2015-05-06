part of dslink.server;

/// a server link for both http and ws
class HttpServerLink implements ServerLink {
  final bool trusted;
  final String dsId;
  final String session;
  Completer<Requester> _onRequesterReadyCompleter = new Completer<Requester>();
  Future<Requester> get onRequesterReady => _onRequesterReadyCompleter.future;

  final Requester requester;
  final Responder responder;
  final PublicKey publicKey;

  /// nonce for authentication, don't overwrite existing nonce
  ECDH _tempNonce;
  /// nonce after user verified the public key
  ECDH _verifiedNonce;

  ECDH get nonce => _verifiedNonce;

  ServerConnection _connection;

  // TODO deprecate this, all dslink need to support it
  final bool enableTimeout;

  final List<String> _saltBases = new List<String>(3);
  final List<int> _saltInc = <int>[0, 0, 0];
  /// 3 salts, salt saltS saltL
  final List<String> salts = new List<String>(3);

  void _updateSalt(int type) {
    _saltInc[type] += DSRandom.instance.nextUint16();
    salts[type] = '${_saltBases[type]}${_saltInc[type].toRadixString(16)}';
  }

  HttpServerLink(String id, this.publicKey, ServerLinkManager linkManager, {NodeProvider nodeProvider, String sessionId, this.trusted: false, this.enableTimeout:false})
      : dsId = id,
        session = sessionId,
        requester = linkManager.getRequester(id),
        responder = (nodeProvider != null) ? linkManager.getResponder(id, nodeProvider, sessionId) : null {
    if (!trusted) {
      for (int i = 0; i < 3; ++i) {
        List<int> bytes = new List<int>(12);
        for (int j = 0; j < 12; ++j) {
          bytes[j] = DSRandom.instance.nextUint8();
        }
        _saltBases[i] = Base64.encode(bytes);
        _updateSalt(i);
      }
    }

    // TODO, need a requester ready property? because client can disconnect and reconnect and change isResponder value
  }
  /// check if public key matchs the dsId
  bool get valid {
    if (trusted) {
      return true;
    }
    return publicKey.verifyDsId(dsId);
  }

  bool isRequester = false;
  /// by default it's a responder only link
  bool isResponder = true;
  void initLink(HttpRequest request, bool clientRequester, bool clientResponder, String serverDsId, String serverKey, 
                {String wsUri:'/ws', String httpUri:'/http', int updateInterval:200}) {
    isRequester = clientResponder;
    isResponder = clientRequester;

    // TODO, dont use hard coded id and public key
    Map respJson = {
      "id": serverDsId,//"broker-dsa-VLK07CSRoX_bBTQm4uDIcgfU-jV-KENsp52KvDG_o8g",
      "publicKey": serverKey,
          //"vvOSmyXM084PKnlBz3SeKScDoFs6I_pdGAdPAB8tOKmA5IUfIlHefdNh1jmVfi1YBTsoYeXm2IH-hUZang48jr3DnjjI3MkDSPo1czrI438Cr7LKrca8a77JMTrAlHaOS2Yd9zuzphOdYGqOFQwc5iMNiFsPdBtENTlx15n4NGDQ6e3d8mrKiSROxYB9LrF1-53goDKvmHYnDA_fbqawokM5oA3sWUIq5uNdp55_cF68Lfo9q-ea8JEsHWyDH73FqNjUaPLFdgMl8aYl-sUGpdlMMMDwRq-hnwG3ad_CX5iFkiHpW-uWucta9i3bljXgyvJ7dtVqEUQBH-GaUGkC-w",
      "wsUri": wsUri,
      "httpUri": httpUri,
      "updateInterval": updateInterval
    };
    if (!trusted) {
      _tempNonce = new ECDH.generate(publicKey);
      respJson["tempKey"] = _tempNonce.encodePublicKey();
      respJson["salt"] = salts[0];
      respJson["saltS"] = salts[1];
      respJson["saltL"] = salts[2];
    }
    updateResponseBeforeWrite(request);
    request.response.write(DsJson.encode(respJson));
    request.response.close();
    print('inited $respJson');
  }

  bool _verifySalt(int type, String hash) {
    if (trusted) {
      return true;
    }
    if (hash == null) {
      return false;
    }
    if (_verifiedNonce != null &&
        _verifiedNonce.verifySalt(salts[type], hash)) {
      _updateSalt(type);
      return true;
    } else if (_tempNonce != null && _tempNonce.verifySalt(salts[type], hash)) {
      _updateSalt(type);
      _nonceChanged();
      return true;
    }
    return false;
  }
  void _nonceChanged() {
    _verifiedNonce = _tempNonce;
    _tempNonce = null;
    if (_connection != null) {
      _connection.close();
      _connection = null;
    }
  }
  void handleHttpUpdate(HttpRequest request) {
    String saltS = request.uri.queryParameters['authS'];
    if (saltS != null) {
      if (_connection is HttpServerConnection && _verifySalt(1, saltS)) {
        // handle http short polling
        (_connection as HttpServerConnection).handleInputS(request, salts[1]);
        return;
      } else {
        throw HttpStatus.UNAUTHORIZED;
      }
    }

    if (!_verifySalt(2, request.uri.queryParameters['authL'])) {
      throw HttpStatus.UNAUTHORIZED;
    }
//    if (requester == null) {
//      throw HttpStatus.FORBIDDEN;
//    }
    if (_connection != null && _connection is! HttpServerConnection) {
      _connection.close();
      _connection = null;
    }
    if (_connection == null) {
      _connection = new HttpServerConnection();
      if (responder != null && isResponder) {
        responder.connection = _connection.responderChannel;
      }
      if (requester != null && isRequester) {
        requester.connection = _connection.requesterChannel;
        if (!_onRequesterReadyCompleter.isCompleted) {
          _onRequesterReadyCompleter.complete(requester);
        }
      }
    }
    _connection.addServerCommand('saltL', salts[2]);
    (_connection as HttpServerConnection).handleInput(request);
  }


  void handleWsUpdate(HttpRequest request) {
    if (!_verifySalt(0, request.uri.queryParameters['auth'])) {
      throw HttpStatus.UNAUTHORIZED;
    }
    WebSocketTransformer.upgrade(request).then((WebSocket websocket) {

      WebSocketConnection wsconnection = createWsConnection(websocket);
      wsconnection.addServerCommand('salt', salts[0]);

      wsconnection.onRequesterReady.then((channel){
        if (_connection != null) {
          _connection.close();
        }
        _connection = wsconnection;
        if (responder != null && isResponder) {
          responder.connection = _connection.responderChannel;
        }
        if (requester != null && isRequester) {
          requester.connection = _connection.requesterChannel;
          if (!_onRequesterReadyCompleter.isCompleted) {
            _onRequesterReadyCompleter.complete(requester);
          }
        }
      });
      if (_connection is! HttpServerConnection) {
        // work around for backward compatibility
        // TODO remove this when all client send blank data to initialize ws
        wsconnection.onRequestReadyCompleter.complete(wsconnection.requesterChannel);;
      }
    });
  }

  WebSocketConnection createWsConnection(WebSocket websocket){
    return new WebSocketConnection(websocket, enableTimeout:enableTimeout);
  }
}
