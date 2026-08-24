import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:dart_cast_example/remote_control_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake session that records every command the UI sends, so tests can
/// assert on what actually reached the "device".
class FakeCastSession extends CastSession {
  final List<String> calls = [];
  final List<double> volumeCalls = [];
  final List<CastMedia> loadedMedia = [];

  FakeCastSession(super.device);

  @override
  Future<void> loadMedia(CastMedia media) async {
    calls.add('loadMedia');
    loadedMedia.add(media);
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> seek(Duration position) async => calls.add('seek');

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
    volumeCalls.add(volume);
  }

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async =>
      calls.add('setSubtitle');

  @override
  Future<void> disconnect() async => calls.add('disconnect');
}

CastDevice _device() => CastDevice(
      id: 'tv-1',
      name: 'Living room TV',
      protocol: CastProtocol.chromecast,
      address: InternetAddress('192.168.2.17'),
      port: 8009,
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  late FakeCastSession session;
  late CastService castService;

  setUp(() {
    session = FakeCastSession(_device());
    castService = CastService(discoveryProviders: []);
  });

  tearDown(() {
    castService.dispose();
  });

  RemoteControlPage page({CastMedia? initialMedia}) => RemoteControlPage(
        session: session,
        device: session.device,
        castService: castService,
        initialMedia: initialMedia,
      );

  group('volume', () {
    testWidgets('slider seeds from the level the device reported',
        (tester) async {
      // The device announced 18% during the connect handshake, before the
      // page ever subscribed to the stream.
      session.updateVolume(0.18);

      await tester.pumpWidget(_wrap(page()));
      // Load media so the player panel (and its volume label) is visible.
      await tester.tap(find.text('Big Buck Bunny (HLS)'));
      await tester.pump();

      expect(find.text('18%'), findsOneWidget);
      // Seeding must be read-only: nothing was sent to the device.
      expect(session.volumeCalls, isEmpty);
    });

    testWidgets('loading media never rewrites the device volume',
        (tester) async {
      session.updateVolume(0.18);
      await tester.pumpWidget(_wrap(page()));

      await tester.tap(find.text('Big Buck Bunny (HLS)'));
      await tester.pump();

      expect(session.calls, ['loadMedia']);
      expect(session.volumeCalls, isEmpty);
    });

    testWidgets('mute sends 0 and unmute restores the device level',
        (tester) async {
      session.updateVolume(0.18);
      await tester.pumpWidget(_wrap(page()));
      await tester.tap(find.text('Big Buck Bunny (HLS)'));
      await tester.pump();

      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(session.volumeCalls, [0.0]);

      await tester.tap(find.byTooltip('Unmute'));
      await tester.pump();
      expect(session.volumeCalls, [0.0, 0.18]);

      // Let the optimistic-slider lock timers finish.
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('layout', () {
    testWidgets('player panel is hidden until media is loaded',
        (tester) async {
      await tester.pumpWidget(_wrap(page()));

      expect(find.byTooltip('Play'), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('player panel is pinned outside the scrolling library',
        (tester) async {
      await tester.pumpWidget(_wrap(page()));
      await tester.tap(find.text('Big Buck Bunny (HLS)'));
      await tester.pump();

      // Panel lives in the Scaffold's bottomNavigationBar slot, not in the
      // library's scroll view.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.bottomNavigationBar, isNotNull);
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byTooltip('Stop'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Slider),
        ),
        findsNothing,
      );
    });

    testWidgets('app bar offers switch-device and disconnect',
        (tester) async {
      await tester.pumpWidget(_wrap(page()));

      expect(find.byTooltip('Switch device'), findsOneWidget);
      expect(find.byTooltip('Disconnect'), findsOneWidget);
    });
  });

  group('library', () {
    testWidgets('tapping an item casts it, tapping it again is a no-op',
        (tester) async {
      // Tall surface so the whole library renders without scrolling.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(page()));

      await tester.tap(find.text('Big Buck Bunny (HLS)'));
      await tester.pump();
      expect(session.loadedMedia, hasLength(1));

      // Same item again: already playing, must not reload. (Scoped to the
      // ListTile — the player panel now shows the same title.)
      await tester.tap(find.descendant(
        of: find.byType(ListTile),
        matching: find.text('Big Buck Bunny (HLS)'),
      ));
      await tester.pump();
      expect(session.loadedMedia, hasLength(1));

      // A different item switches the source.
      await tester.tap(find.text('Elephants Dream (MP4)'));
      await tester.pump();
      expect(session.loadedMedia, hasLength(2));
      expect(session.loadedMedia.last.title, 'Elephants Dream (MP4)');
    });
  });

  group('device switching handoff', () {
    testWidgets('initialMedia auto-loads with its start position preserved',
        (tester) async {
      final resumed = _resumableMp4.copyWith(
        startPosition: const Duration(minutes: 12),
      );

      await tester.pumpWidget(_wrap(page(initialMedia: resumed)));
      await tester.pump();

      expect(session.loadedMedia, hasLength(1));
      expect(
        session.loadedMedia.single.startPosition,
        const Duration(minutes: 12),
      );
      // The panel reflects the resumed item.
      expect(find.byTooltip('Play'), findsOneWidget);
    });
  });

  group('transport', () {
    testWidgets('play, pause and stop reach the session', (tester) async {
      await tester.pumpWidget(_wrap(page()));
      await tester.tap(find.text('Big Buck Bunny (HLS)'));
      await tester.pump();

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(session.calls, contains('play'));

      session.stateMachine
        ..transitionTo(SessionState.connecting)
        ..transitionTo(SessionState.connected)
        ..transitionTo(SessionState.loading)
        ..transitionTo(SessionState.playing);
      await tester.pump();

      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(session.calls, contains('pause'));

      await tester.tap(find.byTooltip('Stop'));
      await tester.pump();
      expect(session.calls, contains('stop'));
      // Stopping clears the now-playing panel.
      expect(find.byTooltip('Play'), findsNothing);
    });
  });
}

/// Shorthand for the demo MP4 item used in the handoff test.
const CastMedia _resumableMp4 = CastMedia(
  url:
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
  type: CastMediaType.mp4,
  title: 'Elephants Dream (MP4)',
);
