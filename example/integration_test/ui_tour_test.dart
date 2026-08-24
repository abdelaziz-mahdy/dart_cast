/// Screenshot tour of the redesigned example UI.
///
/// Renders the real pages against a fake session and writes PNGs to
/// `screenshots/<SHOT_DIR>/` for design review:
///
/// ```sh
/// flutter test integration_test/ui_tour_test.dart -d macos
/// ```
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dart_cast/dart_cast.dart';
import 'package:dart_cast_example/cast_media_demo.dart';
import 'package:dart_cast_example/device_list_sheet.dart';
import 'package:dart_cast_example/remote_control_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class FakeCastSession extends CastSession {
  FakeCastSession(super.device) {
    stateMachine
      ..transitionTo(SessionState.connecting)
      ..transitionTo(SessionState.connected);
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

CastDevice device(String id, String name, CastProtocol protocol, String ip,
        int port) =>
    CastDevice(
      id: id,
      name: name,
      protocol: protocol,
      address: InternetAddress(ip),
      port: port,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: 'after');
  final boundaryKey = GlobalKey();

  const phone = Size(420, 860);
  const desktop = Size(1280, 800);
  var size = phone;

  void setSize(Size s) {
    size = s;
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = s * 2;
    view.devicePixelRatio = 2;
  }

  setUp(() => setSize(phone));
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> shoot(String name) async {
    final boundary = boundaryKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('screenshots/$shotDir/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  }

  Widget frame(Widget child, {Brightness brightness = Brightness.light}) =>
      RepaintBoundary(
        key: boundaryKey,
        child: SizedBox.fromSize(
          size: size,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorSchemeSeed: Colors.deepPurple,
              useMaterial3: true,
              brightness: brightness,
            ),
            home: child,
          ),
        ),
      );

  Widget remote(FakeCastSession session, {CastMedia? initialMedia,
      Brightness brightness = Brightness.light}) {
    return frame(
      brightness: brightness,
      RemoteControlPage(
        session: session,
        device: session.device,
        castService: CastService(discoveryProviders: []),
        initialMedia: initialMedia,
      ),
    );
  }

  testWidgets('remote idle', (t) async {
    final session = FakeCastSession(device('tv-1', 'Living room TV',
        CastProtocol.chromecast, '192.168.2.17', 8009));
    await t.pumpWidget(remote(session));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('01-remote-idle');
  });

  testWidgets('remote playing', (t) async {
    final session = FakeCastSession(device('tv-1', 'Living room TV',
        CastProtocol.chromecast, '192.168.2.17', 8009));
    await t.pumpWidget(
        remote(session, initialMedia: CastMediaDemo.mp4TearsOfSteel));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('02-remote-playing');
  });

  testWidgets('remote playing dark', (t) async {
    final session = FakeCastSession(device('tv-1', 'Living room TV',
        CastProtocol.chromecast, '192.168.2.17', 8009));
    await t.pumpWidget(remote(session,
        initialMedia: CastMediaDemo.mp4TearsOfSteel,
        brightness: Brightness.dark));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('03-remote-playing-dark');
  });

  testWidgets('device sheet while connected', (t) async {
    final devices = [
      device('tv-1', 'Living room TV', CastProtocol.chromecast,
          '192.168.2.17', 8009),
      device('tv-2', 'Bedroom TV', CastProtocol.chromecast, '192.168.2.21',
          8009),
      device('tv-3', 'Samsung 7 Series', CastProtocol.dlna, '192.168.2.30',
          9197),
    ];
    await t.pumpWidget(frame(
      Scaffold(
        body: DeviceListSheet(
          devices: devices,
          isDiscovering: true,
          connectedDeviceId: 'tv-1',
          onDeviceTap: (_) {},
          onStop: () {},
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('04-device-sheet');
  });

  testWidgets('remote idle desktop', (t) async {
    setSize(desktop);
    final session = FakeCastSession(device('tv-1', 'Living room TV',
        CastProtocol.chromecast, '192.168.2.17', 8009));
    await t.pumpWidget(remote(session));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('05-remote-idle-desktop');
  });

  testWidgets('remote playing desktop', (t) async {
    setSize(desktop);
    final session = FakeCastSession(device('tv-1', 'Living room TV',
        CastProtocol.chromecast, '192.168.2.17', 8009));
    await t.pumpWidget(
        remote(session, initialMedia: CastMediaDemo.mp4TearsOfSteel));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('06-remote-playing-desktop');
  });

  testWidgets('remote playing desktop dark', (t) async {
    setSize(desktop);
    final session = FakeCastSession(device('tv-1', 'Living room TV',
        CastProtocol.chromecast, '192.168.2.17', 8009));
    await t.pumpWidget(remote(session,
        initialMedia: CastMediaDemo.mp4TearsOfSteel,
        brightness: Brightness.dark));
    await t.pump(const Duration(milliseconds: 400));
    await shoot('07-remote-playing-desktop-dark');
  });
}
