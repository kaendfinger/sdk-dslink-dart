library dslink.utils;

import "dart:async";
import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import "package:logging/logging.dart";

part "src/utils/better_iterator.dart";
part "src/utils/base64.dart";
part "src/utils/timer.dart";
part "src/utils/stream_controller.dart";
part "src/utils/json.dart";

const String DSA_VERSION = '1.0.1';

Logger _logger;

Logger get logger {
  if (_logger != null) {
    return _logger;
  }

  hierarchicalLoggingEnabled = true;
  _logger = new Logger("DSA");

  _logger.onRecord.listen((record) {
    print("[DSA][${record.level.name}] ${record.message}");
    if (record.error != null) {
      print(record.error);
    }

    if (record.stackTrace != null) {
      print(record.stackTrace);
    }
  });

  return _logger;
}

void updateLogLevel(String name) {
  name = name.trim().toUpperCase();

  Map<String, Level> levels = {};
  for (var l in Level.LEVELS) {
    levels[l.name] = l;
  }

  var l = levels[name];

  if (l != null) {
    logger.level = l;
  }
}

class Interval {
  final Duration duration;

  Interval(this.duration);
  Interval.forMilliseconds(int ms) : this(new Duration(milliseconds: ms));
  Interval.forSeconds(int seconds) : this(new Duration(seconds: seconds));
  Interval.forMinutes(int minutes) : this(new Duration(minutes: minutes));
  Interval.forHours(int hours) : this(new Duration(hours: hours));

  int get inMilliseconds => duration.inMilliseconds;
}

class Scheduler {
  static Timer get currentTimer => Zone.current["dslink.scheduler.timer"];

  static Timer every(interval, action()) {
    Duration duration;

    if (interval is Duration) {
      duration = interval;
    } else if (interval is int) {
      duration = new Duration(milliseconds: interval);
    } else if (interval is Interval) {
      duration = interval.duration;
    } else {
      throw new Exception("Inv");
    }

    return new Timer.periodic(duration, (timer) async {
      await runZoned(action, zoneValues: {
        "dslink.scheduler.timer": timer
      });
    });
  }

  static void later(action()) {
    Timer.run(action);
  }

  static Timer after(Duration duration, action()) {
    return new Timer(duration, action);
  }
}
