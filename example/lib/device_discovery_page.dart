import 'dart:async';

import 'package:dart_cast/dart_cast.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'cast_connector.dart';
import 'device_list_sheet.dart';
import 'remote_control_page.dart';

/// Main page that handles device discovery and connection.
///
/// Demonstrates:
/// - Creating a [CastService] with discovery providers
/// - Starting/stopping device discovery
/// - Displaying discovered devices grouped by protocol
/// - Connecting to a device and navigating to the remote control
class DeviceDiscoveryPage extends StatefulWidget {
  const DeviceDiscoveryPage({super.key});

  @override
  State<DeviceDiscoveryPage> createState() => _DeviceDiscoveryPageState();
}

class _DeviceDiscoveryPageState extends State<DeviceDiscoveryPage> {
  /// The main entry point for dart_cast. Create one per app lifecycle.
  late final CastService _castService;

  /// ValueNotifiers so the bottom sheet can reactively update.
  final _devices = ValueNotifier<List<CastDevice>>([]);
  final _isDiscovering = ValueNotifier<bool>(false);
  StreamSubscription<List<CastDevice>>? _discoverySub;

  // Custom media input state.
  final _customUrlController = TextEditingController();
  final _customSubUrlController = TextEditingController();
  final List<CastMedia> _customMedia = [];

  @override
  void initState() {
    super.initState();

    // Initialize CastService with all three discovery providers.
    // Each provider scans for its respective protocol on the local network.
    //
    // The sessionFactory creates protocol-specific sessions based on the
    // device's protocol. Each protocol has its own session class:
    //   - ChromecastSession: uses TLS + Cast V2 protocol
    //   - AirPlaySession: uses HTTP-based AirPlay protocol
    //   - DlnaSession: uses SOAP/UPnP (requires a DlnaDeviceDescription)
    //
    // For simplicity, this demo creates Chromecast and AirPlay sessions
    // directly. DLNA requires fetching the device description first, which
    // is handled inside connectWithUi (see cast_connector.dart).
    _castService = CastService(
      discoveryProviders: [
        ChromecastDiscoveryProvider(),
        AirPlayDiscoveryProvider(),
        DlnaDiscoveryProvider(),
      ],
      sessionFactory: (device) {
        switch (device.protocol) {
          case CastProtocol.chromecast:
            return ChromecastSession(device: device);
          case CastProtocol.airplay:
            return AirPlaySession(device);
          case CastProtocol.dlna:
            // DLNA sessions need a device description. When using the
            // sessionFactory, you can provide a minimal description.
            // In production, fetch the full description via
            // DlnaDeviceDescription.fetch() before creating the session.
            throw StateError(
              'DLNA devices require description. '
              'Use direct session creation instead.',
            );
        }
      },
    );
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _customUrlController.dispose();
    _customSubUrlController.dispose();
    // Always dispose the CastService to release network resources.
    _castService.dispose();
    super.dispose();
  }

  /// Auto-detects media type from a URL.
  CastMediaType _detectMediaType(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m3u8') || lower.contains('hls')) {
      return CastMediaType.hls;
    }
    if (lower.contains('.ts')) {
      return CastMediaType.mpegTs;
    }
    if (lower.contains('.mkv')) {
      return CastMediaType.mkv;
    }
    return CastMediaType.mp4;
  }

  /// Adds a custom media item from the URL text fields.
  void _addCustomMedia() {
    final url = _customUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter a video URL')));
      return;
    }

    final type = _detectMediaType(url);

    final subtitles = <CastSubtitle>[];
    final subUrl = _customSubUrlController.text.trim();
    if (subUrl.isNotEmpty) {
      subtitles.add(
        CastSubtitle(
          url: subUrl,
          label: 'Custom',
          language: 'und',
          format: subUrl.endsWith('.srt') ? 'srt' : 'vtt',
        ),
      );
    }

    setState(() {
      _customMedia.add(
        CastMedia(
          url: url,
          type: type,
          title: 'Custom Video (${type.name.toUpperCase()})',
          subtitles: subtitles,
        ),
      );
    });

    _customUrlController.clear();
    _customSubUrlController.clear();

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Added to media list')));
  }

  /// Picks a local video file and adds it to the media list.
  ///
  /// The package serves local files over HTTP via its built-in proxy, so a
  /// [CastMedia.file] can be cast to any discovered device just like a remote
  /// URL — no extra setup is needed here.
  Future<void> _pickLocalVideo() async {
    // The example disables the macOS app sandbox, so let file_picker skip its
    // entitlements check there. This is a no-op on every other platform.
    await FilePicker.skipEntitlementsChecks();
    final result = await FilePicker.pickFiles(type: FileType.video);
    // User cancelled the picker, or no path is available (e.g. on web).
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read the selected file path')),
      );
      return;
    }

    final type = _detectMediaType(path);

    // Reuse the subtitle URL field if the user filled it in before picking.
    final subtitles = <CastSubtitle>[];
    final subUrl = _customSubUrlController.text.trim();
    if (subUrl.isNotEmpty) {
      subtitles.add(
        CastSubtitle(
          url: subUrl,
          label: 'Custom',
          language: 'und',
          format: subUrl.endsWith('.srt') ? 'srt' : 'vtt',
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _customMedia.add(
        CastMedia.file(
          filePath: path,
          type: type,
          title: p.basename(path),
          subtitles: subtitles,
        ),
      );
    });

    _customSubUrlController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Added local file to media list')),
    );
  }

  /// Starts device discovery and shows results in a bottom sheet.
  void _startDiscovery() {
    _isDiscovering.value = true;
    _devices.value = [];

    _showDeviceSheet();

    // startDiscovery() returns a stream that emits updated device lists
    // as new devices are found on the network. The stream completes
    // after the timeout (default 10 seconds).
    _discoverySub?.cancel();
    _discoverySub = _castService
        .startDiscovery(timeout: const Duration(seconds: 15))
        .listen(
          (devices) {
            _devices.value = devices;
          },
          onDone: () {
            _isDiscovering.value = false;
          },
          onError: (Object error) {
            _isDiscovering.value = false;
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Discovery error: $error')),
              );
            }
          },
        );
  }

  /// Stops an active discovery scan.
  void _stopDiscovery() {
    _discoverySub?.cancel();
    _castService.stopDiscovery();
    _isDiscovering.value = false;
  }

  /// Connects to the selected device and navigates to the remote control
  /// page. The shared [connectWithUi] flow handles the DLNA description
  /// fetch and AirPlay PIN pairing.
  Future<void> _connectToDevice(CastDevice device) async {
    // Close the bottom sheet
    if (mounted) Navigator.of(context).pop();

    final session = await connectWithUi(context, _castService, device);
    if (session == null || !mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => RemoteControlPage(
              session: session,
              device: device,
              castService: _castService,
              customMedia: _customMedia,
            ),
      ),
    );
  }

  /// Shows a modal bottom sheet with discovered devices.
  void _showDeviceSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        // Use ValueListenableBuilder so the sheet updates reactively
        // when devices are found or discovery state changes.
        return ValueListenableBuilder<List<CastDevice>>(
          valueListenable: _devices,
          builder: (context, devices, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: _isDiscovering,
              builder: (context, isDiscovering, _) {
                return DeviceListSheet(
                  devices: devices,
                  isDiscovering: isDiscovering,
                  onDeviceTap: _connectToDevice,
                  onStop: _stopDiscovery,
                );
              },
            );
          },
        );
      },
    ).then((_) {
      // If the sheet is dismissed, stop discovery.
      if (_isDiscovering.value) _stopDiscovery();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dart_cast Demo'),
        actions: [
          // Log viewer button
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: 'View logs',
            onPressed: () => Navigator.of(context).pushNamed('/logs'),
          ),
          // Cast button in the AppBar — the standard UX pattern.
          ValueListenableBuilder<bool>(
            valueListenable: _isDiscovering,
            builder:
                (context, discovering, _) => IconButton(
                  icon: Icon(discovering ? Icons.cast_connected : Icons.cast),
                  tooltip: 'Discover devices',
                  onPressed: _startDiscovery,
                ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // -- Hero section --
            Center(
              child: Column(
                children: [
                  Icon(
                    Icons.cast,
                    size: 80,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'dart_cast Demo',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Tap the cast icon above to discover\n'
                    'Chromecast, AirPlay, and DLNA devices\n'
                    'on your local network.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _startDiscovery,
                    icon: const Icon(Icons.search),
                    label: const Text('Start Discovery'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            // -- Custom video section --
            Text(
              'Play Custom Video',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Add a custom video URL to the media list. '
              'The format is auto-detected from the URL.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _customUrlController,
              decoration: const InputDecoration(
                labelText: 'Video URL',
                hintText: 'https://example.com/video.mp4',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _customSubUrlController,
              decoration: const InputDecoration(
                labelText: 'Subtitle URL (optional)',
                hintText: 'https://example.com/subs.vtt',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.subtitles),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _addCustomMedia,
              icon: const Icon(Icons.add),
              label: const Text('Add to Media List'),
            ),
            const SizedBox(height: 8),
            Text(
              'Or pick a video file from this device. The package serves it '
              'over HTTP via its built-in proxy, so it casts like any URL.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickLocalVideo,
              icon: const Icon(Icons.folder_open),
              label: const Text('Pick Local Video'),
            ),
            // Show added custom media items.
            if (_customMedia.isNotEmpty) ...[
              const SizedBox(height: 16),
              ..._customMedia.map((media) {
                return Card(
                  child: ListTile(
                    leading: Icon(
                      media.type == CastMediaType.hls
                          ? Icons.live_tv
                          : media.type == CastMediaType.mkv
                          ? Icons.video_library
                          : Icons.movie,
                    ),
                    title: Text(media.title ?? 'Custom Video'),
                    subtitle: Text(
                      '${media.type.name.toUpperCase()}'
                      '${media.subtitles.isNotEmpty ? ' - ${media.subtitles.length} subtitle(s)' : ''}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        setState(() => _customMedia.remove(media));
                      },
                    ),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
