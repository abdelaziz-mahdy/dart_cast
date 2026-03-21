import 'dart:async';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cast_media_demo.dart';

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
/// - Play/pause/stop/seek/volume controls
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

  const RemoteControlPage({
    super.key,
    required this.session,
    required this.device,
    required this.castService,
    this.customMedia = const [],
  });

  @override
  State<RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends State<RemoteControlPage> {
  CastMedia? _currentMedia;
  CastSubtitle? _selectedSubtitle;
  double _volume = 0.25;
  double _lastVolumeBeforeMute = 0.5;
  StreamSubscription<SessionState>? _stateSubscription;
  StreamSubscription<double>? _volumeSubscription;

  late final OptimisticSliderState _seekState;
  late final OptimisticSliderState _volumeState;

  @override
  void initState() {
    super.initState();
    _seekState = OptimisticSliderState(onStateChanged: () {
      if (mounted) setState(() {});
    });
    _volumeState = OptimisticSliderState(onStateChanged: () {
      if (mounted) setState(() {});
    });
    // Track volume from the device stream.
    _volumeSubscription = widget.session.volumeStream.listen((vol) {
      _volume = vol;
    });
    // Auto-pop when the session disconnects (e.g., device-side disconnect)
    _stateSubscription = widget.session.stateStream.listen((state) {
      if (state == SessionState.disconnected && mounted) {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }
    });
  }

  @override
  void dispose() {
    _seekState.dispose();
    _volumeState.dispose();
    _stateSubscription?.cancel();
    _volumeSubscription?.cancel();
    // Stop playback when closing the remote
    widget.session.stop().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.device.name),
          actions: [
            // Disconnect button in the app bar.
            IconButton(
              icon: const Icon(Icons.cast_connected),
              tooltip: 'Disconnect',
              onPressed: _disconnect,
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              children: [
                // -- Session state indicator --
                _buildStateBar(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // -- Device info --
                        _buildDeviceInfo(),
                        const SizedBox(height: 24),
                        // -- Media selector --
                        _buildMediaSelector(),
                        const SizedBox(height: 24),
                        // -- Now playing info --
                        if (_currentMedia != null) ...[
                          _buildNowPlaying(),
                          const SizedBox(height: 24),
                          // -- Seek slider --
                          _buildSeekSlider(),
                          const SizedBox(height: 16),
                          // -- Playback controls --
                          _buildPlaybackControls(),
                          const SizedBox(height: 24),
                          // -- Volume slider --
                          _buildVolumeSlider(),
                          const SizedBox(height: 24),
                          // -- Subtitle selector --
                          if (_currentMedia!.subtitles.isNotEmpty)
                            _buildSubtitleSelector(),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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
      _seekState
          .lock(clamped.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()));
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
      _seekState
          .lock(clamped.inSeconds.toDouble().clamp(0, dur.inSeconds.toDouble()));
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

  /// Shows device name, protocol, and IP address.
  Widget _buildDeviceInfo() {
    return Card(
      child: ListTile(
        leading: Icon(_protocolIcon(widget.device.protocol), size: 32),
        title: Text(widget.device.name),
        subtitle: Text(
          '${widget.device.protocol.name.toUpperCase()} '
          '- ${widget.device.address.address}:${widget.device.port}',
        ),
      ),
    );
  }

  /// Lets the user pick a sample media item to cast.
  Widget _buildMediaSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select Media',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        // List of sample media items + any custom media from the home page.
        ...[...CastMediaDemo.allMedia, ...widget.customMedia].map((media) {
          final isSelected = _currentMedia?.url == media.url;
          return Card(
            color: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: ListTile(
              leading: _mediaTypeIcon(media.type),
              title: Text(media.title ?? 'Untitled'),
              subtitle: Text(
                '${media.type.name.toUpperCase()}'
                '${media.subtitles.isNotEmpty ? ' - ${media.subtitles.length} subtitle(s)' : ''}',
              ),
              trailing: isSelected
                  ? const Icon(Icons.check_circle)
                  : const Icon(Icons.play_circle_outline),
              onTap: () => _loadMedia(media),
            ),
          );
        }),
      ],
    );
  }

  /// Displays the currently loaded media title and thumbnail.
  Widget _buildNowPlaying() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Thumbnail image if available.
            if (_currentMedia!.imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  _currentMedia!.imageUrl!,
                  width: 80,
                  height: 60,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 80,
                    height: 60,
                    color: Colors.grey.shade300,
                    child: const Icon(Icons.broken_image),
                  ),
                ),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentMedia!.title ?? 'Now Playing',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    _currentMedia!.type.name.toUpperCase(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
            final polledSeconds = maxSeconds > 0
                ? position.inSeconds.toDouble().clamp(0.0, maxSeconds)
                : 0.0;
            final displaySeconds = _seekState.displayValue(polledSeconds);

            return Column(
              children: [
                Slider(
                  value: maxSeconds > 0
                      ? displaySeconds.clamp(0.0, maxSeconds)
                      : 0,
                  max: maxSeconds > 0 ? maxSeconds : 1,
                  onChanged: maxSeconds > 0
                      ? (value) => _seekState.onDragUpdate(value)
                      : null,
                  onChangeEnd: maxSeconds > 0
                      ? (value) => _seekState.onDragEnd(value, () {
                            _seek(Duration(seconds: value.toInt()));
                          })
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(
                        Duration(seconds: displaySeconds.toInt()),
                      )),
                      Text(_formatDuration(duration)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Play/pause and disconnect controls.
  Widget _buildPlaybackControls() {
    return StreamBuilder<SessionState>(
      stream: widget.session.stateStream,
      initialData: widget.session.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? SessionState.idle;
        final isPlaying = state == SessionState.playing;
        final isBuffering =
            state == SessionState.buffering || state == SessionState.loading;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Play/Pause toggle
            IconButton.filled(
              iconSize: 48,
              onPressed: isBuffering ? null : (isPlaying ? _pause : _play),
              icon: isBuffering
                  ? const SizedBox(
                      width: 48,
                      height: 48,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                    )
                  : Icon(isPlaying ? Icons.pause : Icons.play_arrow),
              tooltip: isPlaying ? 'Pause' : 'Play',
            ),
            const SizedBox(width: 16),
            // Disconnect button
            IconButton.filled(
              iconSize: 32,
              onPressed: _disconnect,
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              icon: const Icon(Icons.power_settings_new),
              tooltip: 'Disconnect',
            ),
          ],
        );
      },
    );
  }

  /// Volume slider with [OptimisticSliderState] and mute toggle icon.
  Widget _buildVolumeSlider() {
    return StreamBuilder<double>(
      stream: widget.session.volumeStream,
      initialData: _volume,
      builder: (context, snapshot) {
        final polledVol = (snapshot.data ?? 0.25).clamp(0.0, 1.0);
        final displayVol = _volumeState.displayValue(polledVol);

        return Row(
          children: [
            // Mute toggle icon
            IconButton(
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                displayVol <= 0
                    ? Icons.volume_off
                    : displayVol < 0.5
                        ? Icons.volume_down
                        : Icons.volume_up,
              ),
              onPressed: () {
                if (displayVol > 0) {
                  _lastVolumeBeforeMute = displayVol;
                  _setVolume(0);
                  _volumeState.lock(0);
                } else {
                  final restored =
                      _lastVolumeBeforeMute > 0 ? _lastVolumeBeforeMute : 0.5;
                  _setVolume(restored);
                  _volumeState.lock(restored);
                }
              },
              tooltip: displayVol > 0 ? 'Mute' : 'Unmute',
            ),
            Expanded(
              child: Slider(
                value: displayVol.clamp(0.0, 1.0),
                onChanged: (value) => _volumeState.onDragUpdate(value),
                onChangeEnd: (value) => _volumeState.onDragEnd(value, () {
                  _setVolume(value);
                }),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                '${(displayVol * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        );
      },
    );
  }

  /// Subtitle selector using filter chips.
  Widget _buildSubtitleSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Subtitles',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            // "Off" chip to disable subtitles.
            FilterChip(
              label: const Text('Off'),
              selected: _selectedSubtitle == null,
              onSelected: (_) => _setSubtitle(null),
            ),
            // One chip per available subtitle track.
            ..._currentMedia!.subtitles.map((sub) {
              return FilterChip(
                label: Text(sub.label),
                selected: _selectedSubtitle?.language == sub.language,
                onSelected: (_) => _setSubtitle(sub),
              );
            }),
          ],
        ),
      ],
    );
  }

  // -- Actions --

  /// Loads media onto the cast device using [CastSession.loadMedia].
  Future<void> _loadMedia(CastMedia media) async {
    setState(() {
      _currentMedia = media;
      _selectedSubtitle = null;
    });
    try {
      await widget.session.loadMedia(media);
      // Apply default volume to the device after loading.
      await widget.session.setVolume(0.25);
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

  Future<void> _setSubtitle(CastSubtitle? subtitle) async {
    setState(() => _selectedSubtitle = subtitle);
    try {
      await widget.session.setSubtitle(subtitle);
    } catch (e) {
      _showError('Subtitle change failed: $e');
    }
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  IconData _protocolIcon(CastProtocol protocol) {
    switch (protocol) {
      case CastProtocol.chromecast:
        return Icons.cast;
      case CastProtocol.airplay:
        return Icons.airplay;
      case CastProtocol.dlna:
        return Icons.devices_other;
    }
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
