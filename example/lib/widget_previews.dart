/// Widget previews for the example app.
///
/// Run with `flutter widget-preview start` from the `example/` directory to
/// browse these interactively without a cast device on the network.
library;

import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'cast_media_demo.dart';
import 'device_discovery_page.dart';
import 'device_list_sheet.dart';
import 'remote_control_page.dart';

/// The widget preview scaffold runs on the web, where dart:io's real
/// [InternetAddress] constructor throws. The UI only ever reads
/// [InternetAddress.address], so a trivial stand-in keeps previews working.
class _FakeInternetAddress implements InternetAddress {
  @override
  final String address;

  const _FakeInternetAddress(this.address);

  @override
  String get host => address;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Preview-only InternetAddress');
}

/// Fake session so previews can render without a device on the network.
class _PreviewCastSession extends CastSession {
  _PreviewCastSession(super.device) {
    stateMachine
      ..transitionTo(SessionState.connecting)
      ..transitionTo(SessionState.connected);
    // The level "the TV" reported during the connect handshake.
    updateVolume(0.18);
    updateDuration(const Duration(minutes: 36, seconds: 4));
    updatePosition(const Duration(minutes: 12, seconds: 30));
  }

  @override
  Future<void> loadMedia(CastMedia media) async {
    stateMachine
      ..transitionTo(SessionState.loading)
      ..transitionTo(SessionState.playing);
  }

  @override
  Future<void> play() async => stateMachine.transitionTo(SessionState.playing);

  @override
  Future<void> pause() async => stateMachine.transitionTo(SessionState.paused);

  @override
  Future<void> stop() async => stateMachine.transitionTo(SessionState.idle);

  @override
  Future<void> seek(Duration position) async => updatePosition(position);

  @override
  Future<void> setVolume(double volume) async => updateVolume(volume);

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {}

  @override
  Future<void> disconnect() async =>
      stateMachine.transitionTo(SessionState.disconnected);
}

CastDevice _previewDevice() => CastDevice(
      id: 'preview-tv',
      name: 'Living room TV',
      protocol: CastProtocol.chromecast,
      address: const _FakeInternetAddress('192.168.2.17'),
      port: 8009,
    );

Widget _theme(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: Colors.deepPurple,
      useMaterial3: true,
      brightness: brightness,
    ),
    home: child,
  );
}

Widget _remote({CastMedia? initialMedia, Brightness brightness = Brightness.light}) {
  final session = _PreviewCastSession(_previewDevice());
  return _theme(
    brightness: brightness,
    RemoteControlPage(
      session: session,
      device: session.device,
      castService: CastService(discoveryProviders: []),
      initialMedia: initialMedia,
    ),
  );
}

@Preview(name: 'Remote — library, nothing playing', size: Size(420, 860))
Widget remoteIdle() => _remote();

@Preview(name: 'Remote — playing, panel pinned', size: Size(420, 860))
Widget remotePlaying() => _remote(initialMedia: CastMediaDemo.mp4TearsOfSteel);

@Preview(name: 'Remote — playing, dark mode', size: Size(420, 860))
Widget remotePlayingDark() => _remote(
      initialMedia: CastMediaDemo.mp4TearsOfSteel,
      brightness: Brightness.dark,
    );

@Preview(name: 'Discovery page', size: Size(420, 860))
Widget discovery() => _theme(const DeviceDiscoveryPage());

@Preview(name: 'Device sheet — switching while connected', size: Size(420, 640))
Widget deviceSheet() {
  final devices = [
    _previewDevice(),
    CastDevice(
      id: 'preview-bedroom',
      name: 'Bedroom TV',
      protocol: CastProtocol.chromecast,
      address: const _FakeInternetAddress('192.168.2.21'),
      port: 8009,
    ),
    CastDevice(
      id: 'preview-dlna',
      name: 'Samsung 7 Series',
      protocol: CastProtocol.dlna,
      address: const _FakeInternetAddress('192.168.2.30'),
      port: 9197,
    ),
  ];
  return _theme(
    Scaffold(
      body: DeviceListSheet(
        devices: devices,
        isDiscovering: true,
        connectedDeviceId: 'preview-tv',
        onDeviceTap: (_) {},
        onStop: () {},
      ),
    ),
  );
}
