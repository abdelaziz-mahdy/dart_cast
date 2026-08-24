import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';

/// Bottom sheet listing discovered devices, grouped by protocol.
///
/// Used by the discovery page for the first connection and by the remote
/// control page to switch devices mid-session.
class DeviceListSheet extends StatelessWidget {
  final List<CastDevice> devices;
  final bool isDiscovering;
  final ValueChanged<CastDevice> onDeviceTap;
  final VoidCallback onStop;

  /// Device id of the currently connected device, if any. That device is
  /// highlighted and not tappable.
  final String? connectedDeviceId;

  const DeviceListSheet({
    super.key,
    required this.devices,
    required this.isDiscovering,
    required this.onDeviceTap,
    required this.onStop,
    this.connectedDeviceId,
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
        final items = _buildItems(context, grouped);
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
                    TextButton(onPressed: onStop, child: const Text('Stop')),
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
              child:
                  devices.isEmpty
                      ? Center(
                        child: Text(
                          isDiscovering
                              ? 'Searching for devices...'
                              : 'No devices found.\nMake sure you are on the same network\nas your cast devices.',
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                      : ListView.builder(
                        controller: scrollController,
                        itemCount: items.length,
                        itemBuilder: (context, index) => items[index],
                      ),
            ),
          ],
        );
      },
    );
  }

  /// Builds a flat list of widgets: section headers + device tiles.
  List<Widget> _buildItems(
    BuildContext context,
    Map<CastProtocol, List<CastDevice>> grouped,
  ) {
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.15),
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
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
                fontSize: 11,
              ),
            ),
          ),
        );
      }

      // Devices in this group
      for (final device in entry.value) {
        final isConnected = device.id == connectedDeviceId;
        items.add(
          ListTile(
            leading: Icon(_protocolIcon(device.protocol)),
            title: Text(device.name),
            subtitle: Text(
              isConnected
                  ? 'Connected'
                  : '${device.address.address}:${device.port}',
            ),
            trailing:
                isConnected
                    ? Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                    )
                    : const Icon(Icons.chevron_right),
            enabled: !isConnected,
            onTap: isConnected ? null : () => onDeviceTap(device),
          ),
        );
      }
    }
    return items;
  }
}
