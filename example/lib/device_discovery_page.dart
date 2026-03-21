import 'dart:async';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';

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
    // is handled in _connectToDevice below.
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a video URL')),
      );
      return;
    }

    final type = _detectMediaType(url);

    final subtitles = <CastSubtitle>[];
    final subUrl = _customSubUrlController.text.trim();
    if (subUrl.isNotEmpty) {
      subtitles.add(CastSubtitle(
        url: subUrl,
        label: 'Custom',
        language: 'und',
        format: subUrl.endsWith('.srt') ? 'srt' : 'vtt',
      ));
    }

    setState(() {
      _customMedia.add(CastMedia(
        url: url,
        type: type,
        title: 'Custom Video (${type.name.toUpperCase()})',
        subtitles: subtitles,
      ));
    });

    _customUrlController.clear();
    _customSubUrlController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Added to media list')),
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

  /// Shows a connecting dialog with a spinner and device name.
  void _showConnectingDialog(String deviceName) {
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 24),
              Expanded(
                child: Text('Connecting to $deviceName...'),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// Shows a dialog prompting the user to enter the 4-digit AirPlay PIN.
  Future<String?> _showPinDialog() {
    final pinController = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('AirPlay Pairing'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the 4-digit PIN shown on your TV'),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              autofocus: true,
              maxLength: 4,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(pinController.text),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
  }

  /// Connects to the selected device and navigates to the remote control page.
  ///
  /// For DLNA devices, we first fetch the device description XML, then
  /// create the session manually. For other protocols, we use the
  /// CastService.connect() convenience method.
  ///
  /// If the device requires AirPlay pairing, prompts the user for a PIN.
  Future<void> _connectToDevice(CastDevice device) async {
    // Close the bottom sheet
    if (mounted) Navigator.of(context).pop();

    // Show a connecting dialog
    _showConnectingDialog(device.name);

    try {
      CastSession session;

      if (device.protocol == CastProtocol.dlna) {
        // DLNA sessions need a device description from discovery metadata.
        session = DlnaSession.fromDevice(device);
        await session.connect();
      } else {
        // For Chromecast and AirPlay, CastService.connect() uses the
        // sessionFactory to create the appropriate session.
        debugPrint('EXAMPLE: calling _castService.connect(${device.name})...');
        session = await _castService.connect(device);
        debugPrint('EXAMPLE: connect succeeded');
      }

      // Dismiss connecting dialog
      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RemoteControlPage(
              session: session,
              device: device,
              castService: _castService,
              customMedia: _customMedia,
            ),
          ),
        );
      }
    } on NeedsPairingException catch (e) {
      debugPrint('EXAMPLE: caught NeedsPairingException: $e');
      // Dismiss connecting dialog
      if (mounted) Navigator.of(context).pop();

      // Trigger PIN display on TV
      debugPrint('EXAMPLE: triggering PIN display on TV...');
      // Fire-and-forget — don't wait for response, show dialog immediately
      AirPlayPairSetup(host: device.address.address, port: device.port)
          .startPinDisplay();
      debugPrint('EXAMPLE: PIN display request sent');

      // Show PIN dialog
      final pin = await _showPinDialog();
      if (pin != null && pin.length == 4) {
        // Re-show connecting dialog
        _showConnectingDialog(device.name);
        try {
          // Create a fresh AirPlaySession for pairing
          final session = AirPlaySession(device);
          await session.pairSetup(pin);
          // Retry connect with the newly stored credentials
          await session.connect();

          // Dismiss connecting dialog
          if (mounted) Navigator.of(context).pop();

          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RemoteControlPage(
                  session: session,
                  device: device,
                  castService: _castService,
                ),
              ),
            );
          }
        } catch (e) {
          // Dismiss connecting dialog
          if (mounted) Navigator.of(context).pop();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Pairing failed: $e')),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('EXAMPLE: catch-all error (${e.runtimeType}): $e');
      // Dismiss connecting dialog
      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
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
                return _DeviceListSheet(
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
            builder: (context, discovering, _) => IconButton(
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
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
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

/// Internal widget for the device list bottom sheet.
class _DeviceListSheet extends StatelessWidget {
  final List<CastDevice> devices;
  final bool isDiscovering;
  final ValueChanged<CastDevice> onDeviceTap;
  final VoidCallback onStop;

  const _DeviceListSheet({
    required this.devices,
    required this.isDiscovering,
    required this.onDeviceTap,
    required this.onStop,
  });

  /// Returns an icon for each protocol type.
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

  /// Protocol display order: Chromecast first (best local file support).
  static const _protocolOrder = [
    CastProtocol.chromecast,
    CastProtocol.dlna,
    CastProtocol.airplay,
  ];

  /// Known limitations per protocol for user guidance.
  String? _protocolNote(CastProtocol protocol) {
    switch (protocol) {
      case CastProtocol.chromecast:
        return null; // Best support, no caveats
      case CastProtocol.dlna:
        return 'Uses HTTP/1.0 for compatibility. MKV with embedded subs recommended';
      case CastProtocol.airplay:
        return 'Video casting not supported on some smart TVs';
    }
  }

  /// Groups devices by their protocol for organized display.
  Map<CastProtocol, List<CastDevice>> _groupByProtocol() {
    final grouped = <CastProtocol, List<CastDevice>>{};
    for (final device in devices) {
      grouped.putIfAbsent(device.protocol, () => []).add(device);
    }
    // Sort by preferred protocol order
    final sorted = <CastProtocol, List<CastDevice>>{};
    for (final p in _protocolOrder) {
      if (grouped.containsKey(p)) sorted[p] = grouped[p]!;
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupByProtocol();

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    'Devices',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  if (isDiscovering)
                    TextButton(
                      onPressed: onStop,
                      child: const Text('Stop'),
                    ),
                ],
              ),
            ),
            if (isDiscovering)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: LinearProgressIndicator(),
              ),
            // Device list
            Expanded(
              child: devices.isEmpty
                  ? Center(
                      child: Text(
                        isDiscovering
                            ? 'Searching for devices...'
                            : 'No devices found.\nMake sure you are on the same network\nas your cast devices.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: _buildItems(context, grouped).length,
                      itemBuilder: (context, index) {
                        return _buildItems(context, grouped)[index];
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Builds a flat list of widgets: section headers + device tiles.
  List<Widget> _buildItems(
      BuildContext context, Map<CastProtocol, List<CastDevice>> grouped) {
    final items = <Widget>[];
    for (final entry in grouped.entries) {
      final protocol = entry.key;
      final note = _protocolNote(protocol);

      // Protocol group header with optional "Recommended" badge
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Icon(_protocolIcon(protocol), size: 18),
              const SizedBox(width: 8),
              Text(
                protocol.name.toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
              if (protocol == CastProtocol.chromecast) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Recommended',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );

      // Limitation note if applicable
      if (note != null) {
        items.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(42, 0, 16, 4),
            child: Text(
              note,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ),
        );
      }

      // Devices in this group
      for (final device in entry.value) {
        items.add(
          ListTile(
            leading: Icon(_protocolIcon(device.protocol)),
            title: Text(device.name),
            subtitle: Text('${device.address.address}:${device.port}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onDeviceTap(device),
          ),
        );
      }
    }
    return items;
  }
}
