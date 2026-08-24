import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'device_discovery_page.dart';
import 'log_viewer_page.dart';

/// Global log storage for the example app.
final logEntries = ValueNotifier<List<LogEntry>>([]);

class LogEntry {
  final DateTime time;
  final String level;
  final String message;
  LogEntry(this.level, this.message) : time = DateTime.now();
}

void main() {
  // Wire up dart_cast internal logging so we can see what's happening.
  CastLogger.setCallback((level, message) {
    if (kDebugMode) {
      debugPrint('[dart_cast:$level] $message');
    }
    logEntries.value = [...logEntries.value, LogEntry(level, message)];
  });

  runApp(const DartCastExampleApp());
}

/// Root widget for the dart_cast example application.
///
/// Demonstrates how to integrate dart_cast into a Flutter app for
/// discovering and casting media to Chromecast, AirPlay, and DLNA devices.
class DartCastExampleApp extends StatelessWidget {
  const DartCastExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'dart_cast Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const DeviceDiscoveryPage(),
      routes: {'/logs': (_) => const LogViewerPage()},
    );
  }
}
