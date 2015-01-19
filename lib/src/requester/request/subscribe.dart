part of dslink.requester;

class RequesterSubscribeUpdate extends RequesterUpdate {
  String path;
  String ts;
  Object value;
  Map meta;
  RequesterSubscribeUpdate(this.path, this.value, this.ts, {this.meta});
  String get status {
    if (meta != null && meta['status'] is String) {
      return meta['status'];
    }
    return null;
  }
  int get count {
    if (meta != null && meta['count'] is int) {
      return meta['count'];
    }
    return null;
  }
  num get sum {
    if (meta != null && meta['sum'] is num) {
      return meta['sum'];
    }
    return double.NAN;
  }
  num get max {
    if (meta != null && meta['max'] is num) {
      return meta['max'];
    }
    return double.NAN;
  }
  num get min {
    if (meta != null && meta['min'] is num) {
      return meta['min'];
    }
    return double.NAN;
  }
}
class SubscribeRequest extends Request {
  final Map<String, ReqSubscribeController> subsriptions = new Map<String, ReqSubscribeController>();

  SubscribeRequest(Requester requester, int rid) : super(requester, rid, null);

  @override
  void _update(Map m) {
    List updates = m['updates'];
    if (updates is List) {
      for (Object update in updates) {
        String path;
        Object value;
        String ts;
        Map meta;
        if (update is Map) {
          if (update['path'] is String && update['ts'] is String) {
            path = update['path'];
            ts = update['ts'];
          } else {
            continue; // invalid response
          }
          value = update['value'];
          meta = update;
        } else if (update is List && update.length > 2) {
          if (update.length > 0 && update[0] is String) {
            path = update[0];
            value = update[1];
            ts = update[2];
          } else {
            continue; // invalid response
          }
        } else {
          continue; // invalid response
        }
        if (subsriptions.containsKey(path)) {
          subsriptions[path]._controller.add(new RequesterSubscribeUpdate(path, value, ts, meta: meta));
        }
      }
    }
  }


  HashSet<String> _changedPaths = new HashSet<String>();
  void addSubscription(ReqSubscribeController controller) {
    String path = controller.node.path;
    if (!subsriptions.containsKey(path)) {
      subsriptions[path] = controller;
      if (_changedPaths.contains(path)) {
        _changedPaths.remove(path);
      } else {
        requester.addProcessor(_sendSubscriptionReuests);
        _changedPaths.add(path);
      }
    }
  }
  void removeSubscription(ReqSubscribeController controller) {
    String path = controller.node.path;
    if (subsriptions.containsKey(path)) {
      subsriptions.remove(path);
      if (_changedPaths.contains(path)) {
        _changedPaths.remove(path);
      } else {
        requester.addProcessor(_sendSubscriptionReuests);
        _changedPaths.add(path);
      }
    }
  }
  void _sendSubscriptionReuests() {
    if (requester.connection == null) {
      return;
    }
    List toAdd = [];
    List toRemove = [];
    HashSet<String> processingPaths = _changedPaths;
    _changedPaths = new HashSet<String>();
    for (String path in processingPaths) {
      if (subsriptions.containsKey(path)) {
        toAdd.add(path);
      } else {
        toRemove.add(path);
      }
    }
    if (!toAdd.isEmpty) {
      requester._sendRequest({
        'method': 'subscribe',
        'paths': toAdd
      }, null);
    }
    if (!toRemove.isEmpty) {
      requester._sendRequest({
        'method': 'unsubscribe',
        'paths': toRemove
      }, null);
    }
  }
}
class ReqSubscribeController {
  final RequesterNode node;

  StreamController<RequesterSubscribeUpdate> _controller;
  Stream<RequesterSubscribeUpdate> _stream;
  HashSet _listeners;
  ReqSubscribeController(this.node) {
    _controller = new StreamController<RequesterSubscribeUpdate>();
    _stream = _controller.stream.asBroadcastStream(onListen: _onListen, onCancel: _onCancel);
    _listeners = new HashSet();
  }



  bool _subscribing = false;
  void _onListen(StreamSubscription<RequesterSubscribeUpdate> listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
      if (!_subscribing) {
        node.requester._subsciption.addSubscription(this);
        _subscribing = true;
      }
    }
  }

  void _onCancel(StreamSubscription<RequesterSubscribeUpdate> listener) {
    if (_listeners.contains(listener)) {
      _listeners.remove(listener);
      if (_listeners.isEmpty) {
        _destroy();
      }
    }
  }

  void _destroy() {
    if (_subscribing != null) {
      node.requester._subsciption.removeSubscription(this);
    }
    _controller.close();
    node._subscribeController = null;
  }
}
