import 'dart:async';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cast_connector.dart';
import 'cast_media_demo.dart';
import 'device_list_sheet.dart';

/// Prevents slider jitter by ignoring polled values during and after user
/// interaction.
///
/// State machine: IDLE -> DRAGGING -> LOCKED -> IDLE
/// - IDLE: display polled value from the device
/// - DRAGGING: display user's drag position, ignore polls
/// - LOCKED: display last sent value for [_lockDuration], ignore polls
class OptimisticSliderState {
  double? _dragValue;
  double? _lockedValue;
  Timer? _lockTimer;
  final VoidCallback _onStateChanged;
  static const _lockDuration = Duration(seconds: 3);

  OptimisticSliderState({required VoidCallback onStateChanged})
    : _onStateChanged = onStateChanged;

  double displayValue(double polledValue) {
    return _dragValue ?? _lockedValue ?? polledValue;
  }

  bool get isDragging => _dragValue != null;

  void onDragUpdate(double value) {
    _lockTimer?.cancel();
    _lockedValue = null;
    _dragValue = value;
    _onStateChanged();
  }

  void onDragEnd(double value, VoidCallback onSend) {
    _dragValue = null;
    _lock(value);
    onSend();
  }

  /// Lock to a value after a programmatic action (keyboard shortcut, mute).
  void lock(double value) {
    _lock(value);
  }

  void _lock(double value) {
    _lockedValue = value;
    _lockTimer?.cancel();
    _lockTimer = Timer(_lockDuration, () {
      _lockedValue = null;
      _onStateChanged();
    });
    _onStateChanged();
  }

  void dispose() {
    _lockTimer?.cancel();
  }
}

/// Remote control page for an active cast session.
///
/// Demonstrates:
/// - Reactive UI via [StreamBuilder] for position, duration, state, and volume
/// - Loading media with [CastSession.loadMedia]
/// - A pinned player panel with play/pause/stop/seek/volume controls
/// - Volume seeded from the level the device itself reports
/// - Switching to another device mid-session, resuming from the same position
/// - Optimistic slider state to prevent jitter
/// - Keyboard shortcuts (Space, arrows, M)
/// - Subtitle selection
/// - Graceful error handling
/// - Disconnecting and disposing resources
class RemoteControlPage extends StatefulWidget {
  final CastSession session;
  final CastDevice device;
  final CastService castService;
  final List<CastMedia> customMedia;

  /// Media to load as soon as the page opens. Used when switching devices to
  /// resume what was playing on the previous device.
  final CastMedia? initialMedia;

  const RemoteControlPage({
    super.key,
    required this.session,
    required this.device,
    required this.castService,
    this.customMedia = const [],
    this.initialMedia,
  });

  @override
  State<RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends State<RemoteControlPage> {
  CastMedia? _currentMedia;
  CastSubtitle? _selectedSubtitle;

  /// Last known device volume. Seeded from what the device reported during
  /// the connect handshake — never a made-up default that would blast the
  /// TV when the user first touches the slider.
  late double _volume;
  late double _lastVolumeBeforeMute;

  StreamSubscription<SessionState>? _stateSubscription;
  StreamSubscription<double>? _volumeSubscription;

  /// Set while transferring the session to another device, so the
  /// disconnect of the old session doesn't auto-pop this page.
  bool _switching = false;

  late final OptimisticSliderState _seekState;
  late final OptimisticSliderState _volumeState;

  // Discovery state for the switch-device sheet.
  final _switchDevices = ValueNotifier<List<CastDevice>>([]);
  final _switchDiscovering = ValueNotifier<bool>(false);
  StreamSubscription<List<CastDevice>>? _switchDiscoverySub;

  @override
  void initState() {
    super.initState();
    _volume = widget.session.volume ?? 0.5;
    _lastVolumeBeforeMute = _volume > 0 ? _volume : 0.5;
    _seekState = OptimisticSliderState(
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );
    _volumeState = OptimisticSliderState(
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    );
    // Track volume from the device stream.
    _volumeSubscription = widget.session.volumeStream.listen((vol) {
      _volume = vol;
    });
    // Auto-pop when the session disconnects (e.g., device-side disconnect)
    _stateSubscription = widget.session.stateStream.listen((state) {
      if (state == SessionState.disconnected && mounted && !_switching) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }
    });
    // Resume media handed over from a previous device.
    final initial = widget.initialMedia;
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMedia(initial);
      });
    }
  }

  @override
  void dispose() {
    _seekState.dispose();
    _volumeState.dispose();
    _stateSubscription?.cancel();
    _volumeSubscription?.cancel();
    _switchDiscoverySub?.cancel();
    _switchDevices.dispose();
    _switchDiscovering.dispose();
    // Stop playback when closing the remote (no-op if already switched away).
    if (!_switching) {
      widget.session.stop().catchError((_) {});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.device.name, overflow: TextOverflow.ellipsis),
              Text(
                '${widget.device.protocol.name.toUpperCase()} '
                '${widget.device.address.address}:${widget.device.port}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: 'Switch device',
              onPressed: _showSwitchDeviceSheet,
            ),
            IconButton(
              icon: const Icon(Icons.power_settings_new),
              tooltip: 'Disconnect',
              onPressed: _disconnect,
            ),
          ],
        ),
        body: Column(
          children: [
            _buildStateBar(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 500),
                  child: _buildMediaLibrary(),
                ),
              ),
            ),
          ],
        ),
        // The player panel stays pinned at the bottom, out of the media
        // list's scroll, so the controls never bury under the library.
        bottomNavigationBar: _currentMedia != null ? _buildPlayerPanel() : null,
      ),
    );
  }

  // -- Keyboard shortcuts --

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Space: play/pause
    if (key == LogicalKeyboardKey.space) {
      final state = widget.session.state;
      if (state == SessionState.playing) {
        _pause();
      } else {
        _play();
      }
      return KeyEventResult.handled;
    }

    // Left arrow: seek back 10s
    if (key == LogicalKeyboardKey.arrowLeft) {
      final dur = widget.session.duration;
      if (dur <= Duration.zero) return KeyEventResult.ignored;
      final pos = widget.session.position;
      final target = pos - const Duration(seconds: 10);
      final clamped = target.isNegative ? Duration.zero : target;
      _seek(clamped);
      _seekState.lock(
        clamped.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()),
      );
      return KeyEventResult.handled;
    }

    // Right arrow: seek forward 30s
    if (key == LogicalKeyboardKey.arrowRight) {
      final dur = widget.session.duration;
      if (dur <= Duration.zero) return KeyEventResult.ignored;
      final pos = widget.session.position;
      final target = pos + const Duration(seconds: 30);
      final clamped = target > dur ? dur : target;
      _seek(clamped);
      _seekState.lock(
        clamped.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()),
      );
      return KeyEventResult.handled;
    }

    // Up arrow: volume up
    if (key == LogicalKeyboardKey.arrowUp) {
      final vol = _volumeState.displayValue(_volume.clamp(0.0, 1.0));
      final newVol = (vol + 0.1).clamp(0.0, 1.0);
      _setVolume(newVol);
      _volumeState.lock(newVol);
      return KeyEventResult.handled;
    }

    // Down arrow: volume down
    if (key == LogicalKeyboardKey.arrowDown) {
      final vol = _volumeState.displayValue(_volume.clamp(0.0, 1.0));
      final newVol = (vol - 0.1).clamp(0.0, 1.0);
      _setVolume(newVol);
      _volumeState.lock(newVol);
      return KeyEventResult.handled;
    }

    // M: mute toggle
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // -- Widgets --

  /// Shows the current session state as a colored bar at the top.
  Widget _buildStateBar() {
    // Use StreamBuilder to reactively update when session state changes.
    return StreamBuilder<SessionState>(
      stream: widget.session.stateStream,
      initialData: widget.session.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? SessionState.disconnected;
        final (color, label) = _stateAppearance(state);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 6),
          color: color.withValues(alpha: 0.15),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        );
      },
    );
  }

  /// Returns color and label for each session state.
  (Color, String) _stateAppearance(SessionState state) {
    switch (state) {
      case SessionState.connecting:
        return (Colors.orange, 'CONNECTING...');
      case SessionState.connected:
        return (Colors.green, 'CONNECTED');
      case SessionState.loading:
        return (Colors.blue, 'LOADING MEDIA...');
      case SessionState.playing:
        return (Colors.green, 'PLAYING');
      case SessionState.paused:
        return (Colors.amber, 'PAUSED');
      case SessionState.buffering:
        return (Colors.blue, 'BUFFERING...');
      case SessionState.idle:
        return (Colors.grey, 'IDLE');
      case SessionState.disconnected:
        return (Colors.red, 'DISCONNECTED');
    }
  }

  /// Scrollable media library. Tapping an item casts it; the item that is
  /// currently on the device is marked and tapping it again is a no-op.
  Widget _buildMediaLibrary() {
    final allMedia = [...CastMediaDemo.allMedia, ...widget.customMedia];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      children: [
        Text('Library', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          _currentMedia == null
              ? 'Pick something to cast to ${widget.device.name}.'
              : 'Tap another item to switch what is playing.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ...allMedia.map((media) {
          final isCurrent = _isCurrentMedia(media);
          return Card(
            color:
                isCurrent
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
            child: ListTile(
              leading: _mediaTypeIcon(media.type),
              title: Text(media.title ?? 'Untitled'),
              subtitle: Text(
                '${media.type.name.toUpperCase()}'
                '${media.subtitles.isNotEmpty ? ' - ${media.subtitles.length} subtitle(s)' : ''}',
              ),
              trailing:
                  isCurrent
                      ? Icon(
                        Icons.play_circle,
                        color: Theme.of(context).colorScheme.primary,
                      )
                      : const Icon(Icons.play_circle_outline),
              onTap: isCurrent ? null : () => _loadMedia(media),
            ),
          );
        }),
      ],
    );
  }

  /// Whether [media] is the item currently on the device.
  ///
  /// Compared by URL, type, and title rather than URL alone: the demo list
  /// reuses one URL under two container types, and a device-switch handoff
  /// carries a [CastMedia.copyWith] copy rather than the identical instance.
  bool _isCurrentMedia(CastMedia media) {
    final current = _currentMedia;
    return current != null &&
        current.url == media.url &&
        current.type == media.type &&
        current.title == media.title;
  }

  /// Pinned bottom panel with now-playing info, seek, transport, volume, and
  /// subtitle controls.
  Widget _buildPlayerPanel() {
    final media = _currentMedia!;
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        // heightFactor shrink-wraps the panel: a plain Center would expand
        // to every pixel the Scaffold offers the bottom bar and squeeze the
        // library to zero height.
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Now playing row
                  Row(
                    children: [
                      _mediaTypeIcon(media.type),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          media.title ?? 'Now Playing',
                          style: Theme.of(context).textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (media.subtitles.isNotEmpty) _buildSubtitleButton(),
                    ],
                  ),
                  // Seek slider
                  _buildSeekSlider(),
                  // Transport + volume
                  Row(
                    children: [
                      // Volume cluster
                      _buildMuteButton(),
                      Expanded(child: _buildVolumeSlider()),
                      SizedBox(width: 40, child: _buildVolumeLabel()),
                      const SizedBox(width: 8),
                      // Transport cluster
                      IconButton(
                        iconSize: 28,
                        onPressed: _stop,
                        icon: const Icon(Icons.stop),
                        tooltip: 'Stop',
                      ),
                      _buildPlayPauseButton(),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Play/pause toggle that reflects the live session state.
  Widget _buildPlayPauseButton() {
    return StreamBuilder<SessionState>(
      stream: widget.session.stateStream,
      initialData: widget.session.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? SessionState.idle;
        final isPlaying = state == SessionState.playing;
        final isBuffering =
            state == SessionState.buffering || state == SessionState.loading;

        return IconButton.filled(
          iconSize: 36,
          onPressed: isBuffering ? null : (isPlaying ? _pause : _play),
          icon:
              isBuffering
                  ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  )
                  : Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          tooltip: isPlaying ? 'Pause' : 'Play',
        );
      },
    );
  }

  /// Seek slider using [OptimisticSliderState] to prevent jitter.
  Widget _buildSeekSlider() {
    return StreamBuilder<Duration>(
      stream: widget.session.positionStream,
      initialData: widget.session.position,
      builder: (context, posSnapshot) {
        return StreamBuilder<Duration>(
          stream: widget.session.durationStream,
          initialData: widget.session.duration,
          builder: (context, durSnapshot) {
            final position = posSnapshot.data ?? Duration.zero;
            final duration = durSnapshot.data ?? Duration.zero;
            final maxSeconds = duration.inSeconds.toDouble();
            final polledSeconds =
                maxSeconds > 0
                    ? position.inSeconds.toDouble().clamp(0.0, maxSeconds)
                    : 0.0;
            final displaySeconds = _seekState.displayValue(polledSeconds);

            return Row(
              children: [
                Text(
                  _formatDuration(Duration(seconds: displaySeconds.toInt())),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Expanded(
                  child: Slider(
                    value:
                        maxSeconds > 0
                            ? displaySeconds.clamp(0.0, maxSeconds)
                            : 0,
                    max: maxSeconds > 0 ? maxSeconds : 1,
                    onChanged:
                        maxSeconds > 0
                            ? (value) => _seekState.onDragUpdate(value)
                            : null,
                    onChangeEnd:
                        maxSeconds > 0
                            ? (value) => _seekState.onDragEnd(value, () {
                              _seek(Duration(seconds: value.toInt()));
                            })
                            : null,
                  ),
                ),
                Text(
                  _formatDuration(duration),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Mute toggle icon reflecting the current volume.
  Widget _buildMuteButton() {
    return StreamBuilder<double>(
      stream: widget.session.volumeStream,
      initialData: widget.session.volume ?? _volume,
      builder: (context, snapshot) {
        final polledVol = (snapshot.data ?? _volume).clamp(0.0, 1.0);
        final displayVol = _volumeState.displayValue(polledVol);
        return IconButton(
          icon: Icon(
            displayVol <= 0
                ? Icons.volume_off
                : displayVol < 0.5
                ? Icons.volume_down
                : Icons.volume_up,
          ),
          onPressed: _toggleMute,
          tooltip: displayVol > 0 ? 'Mute' : 'Unmute',
        );
      },
    );
  }

  /// Volume slider with [OptimisticSliderState], seeded from the device.
  Widget _buildVolumeSlider() {
    return StreamBuilder<double>(
      stream: widget.session.volumeStream,
      initialData: widget.session.volume ?? _volume,
      builder: (context, snapshot) {
        final polledVol = (snapshot.data ?? _volume).clamp(0.0, 1.0);
        final displayVol = _volumeState.displayValue(polledVol);

        return Slider(
          value: displayVol.clamp(0.0, 1.0),
          onChanged: (value) => _volumeState.onDragUpdate(value),
          onChangeEnd:
              (value) => _volumeState.onDragEnd(value, () {
                _setVolume(value);
              }),
        );
      },
    );
  }

  Widget _buildVolumeLabel() {
    return StreamBuilder<double>(
      stream: widget.session.volumeStream,
      initialData: widget.session.volume ?? _volume,
      builder: (context, snapshot) {
        final polledVol = (snapshot.data ?? _volume).clamp(0.0, 1.0);
        final displayVol = _volumeState.displayValue(polledVol);
        return Text(
          '${(displayVol * 100).round()}%',
          style: Theme.of(context).textTheme.bodySmall,
        );
      },
    );
  }

  /// Subtitle picker as a popup menu in the player panel.
  Widget _buildSubtitleButton() {
    final subtitles = _currentMedia!.subtitles;
    return PopupMenuButton<CastSubtitle?>(
      icon: Icon(
        _selectedSubtitle != null ? Icons.subtitles : Icons.subtitles_outlined,
        color:
            _selectedSubtitle != null
                ? Theme.of(context).colorScheme.primary
                : null,
      ),
      tooltip: 'Subtitles',
      onSelected: (_) {},
      itemBuilder:
          (context) => [
            CheckedPopupMenuItem<CastSubtitle?>(
              value: null,
              checked: _selectedSubtitle == null,
              onTap: () => _setSubtitle(null),
              child: const Text('Off'),
            ),
            ...subtitles.map(
              (sub) => CheckedPopupMenuItem<CastSubtitle?>(
                value: sub,
                checked: _selectedSubtitle?.language == sub.language,
                onTap: () => _setSubtitle(sub),
                child: Text(sub.label),
              ),
            ),
          ],
    );
  }

  // -- Actions --

  /// Loads media onto the cast device using [CastSession.loadMedia].
  ///
  /// Deliberately does NOT touch the device volume: whatever level the TV
  /// is already at is what the user expects to keep hearing.
  Future<void> _loadMedia(CastMedia media) async {
    setState(() {
      _currentMedia = media;
      _selectedSubtitle = media.defaultSubtitle;
    });
    try {
      await widget.session.loadMedia(media);
    } catch (e) {
      _showError('Failed to load media: $e');
    }
  }

  Future<void> _play() async {
    try {
      await widget.session.play();
    } catch (e) {
      _showError('Play failed: $e');
    }
  }

  Future<void> _pause() async {
    try {
      await widget.session.pause();
    } catch (e) {
      _showError('Pause failed: $e');
    }
  }

  Future<void> _stop() async {
    try {
      await widget.session.stop();
      setState(() => _currentMedia = null);
    } catch (e) {
      _showError('Stop failed: $e');
    }
  }

  Future<void> _seek(Duration position) async {
    try {
      await widget.session.seek(position);
    } catch (e) {
      _showError('Seek failed: $e');
    }
  }

  Future<void> _setVolume(double volume) async {
    try {
      await widget.session.setVolume(volume);
    } catch (e) {
      _showError('Volume change failed: $e');
    }
  }

  void _toggleMute() {
    final vol = _volumeState.displayValue(_volume.clamp(0.0, 1.0));
    if (vol > 0) {
      _lastVolumeBeforeMute = vol;
      _setVolume(0);
      _volumeState.lock(0);
    } else {
      final restored = _lastVolumeBeforeMute > 0 ? _lastVolumeBeforeMute : 0.5;
      _setVolume(restored);
      _volumeState.lock(restored);
    }
  }

  Future<void> _setSubtitle(CastSubtitle? subtitle) async {
    setState(() => _selectedSubtitle = subtitle);
    try {
      await widget.session.setSubtitle(subtitle);
    } catch (e) {
      _showError('Subtitle change failed: $e');
    }
  }

  // -- Device switching --

  /// Discovers devices and shows them in a sheet. Picking one transfers the
  /// session: the current media resumes on the new device from the current
  /// position.
  void _showSwitchDeviceSheet() {
    _switchDiscovering.value = true;
    _switchDevices.value = [];

    _switchDiscoverySub?.cancel();
    _switchDiscoverySub = widget.castService
        .startDiscovery(timeout: const Duration(seconds: 15))
        .listen(
          (devices) => _switchDevices.value = devices,
          onDone: () => _switchDiscovering.value = false,
          onError: (Object error) {
            _switchDiscovering.value = false;
            _showError('Discovery error: $error');
          },
        );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return ValueListenableBuilder<List<CastDevice>>(
          valueListenable: _switchDevices,
          builder: (context, devices, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: _switchDiscovering,
              builder: (context, isDiscovering, _) {
                return DeviceListSheet(
                  devices: devices,
                  isDiscovering: isDiscovering,
                  connectedDeviceId: widget.device.id,
                  onDeviceTap: (device) {
                    Navigator.of(sheetContext).pop();
                    _switchToDevice(device);
                  },
                  onStop: _stopSwitchDiscovery,
                );
              },
            );
          },
        );
      },
    ).then((_) => _stopSwitchDiscovery());
  }

  void _stopSwitchDiscovery() {
    _switchDiscoverySub?.cancel();
    widget.castService.stopDiscovery();
    _switchDiscovering.value = false;
  }

  Future<void> _switchToDevice(CastDevice device) async {
    // Capture playback context before tearing the old session down.
    final media = _currentMedia;
    final position = widget.session.position;

    _switching = true;
    try {
      await widget.session.disconnect();
    } catch (_) {
      // Old session is going away regardless.
    }

    if (!mounted) return;
    final session = await connectWithUi(context, widget.castService, device);
    if (session == null) {
      // Connection to the new device failed and the old one is gone —
      // fall back to the discovery page.
      _switching = false;
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder:
            (_) => RemoteControlPage(
              session: session,
              device: device,
              castService: widget.castService,
              customMedia: widget.customMedia,
              initialMedia: media?.copyWith(startPosition: position),
            ),
      ),
    );
  }

  /// Disconnects from the device and pops back to the discovery page.
  Future<void> _disconnect() async {
    try {
      await widget.session.disconnect();
    } catch (_) {
      // Best effort — navigate back regardless.
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // -- Helpers --

  /// Formats a Duration as mm:ss or hh:mm:ss.
  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  Widget _mediaTypeIcon(CastMediaType type) {
    switch (type) {
      case CastMediaType.hls:
        return const Icon(Icons.live_tv);
      case CastMediaType.mp4:
        return const Icon(Icons.movie);
      case CastMediaType.mkv:
        return const Icon(Icons.video_library);
      case CastMediaType.mpegTs:
        return const Icon(Icons.video_file);
    }
  }
}
