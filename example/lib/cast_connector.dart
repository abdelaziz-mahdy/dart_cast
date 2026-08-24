import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';

/// Shared connection flow used by the discovery page and by the remote
/// control page when switching devices mid-session.
///
/// Handles the protocol differences (DLNA needs a device description,
/// AirPlay may need PIN pairing) and drives the connecting/PIN dialogs.
/// Returns the connected session, or null if the user cancelled or the
/// connection failed (an error snackbar is shown in that case).
Future<CastSession?> connectWithUi(
  BuildContext context,
  CastService castService,
  CastDevice device,
) async {
  _showConnectingDialog(context, device.name);

  try {
    CastSession session;

    if (device.protocol == CastProtocol.dlna) {
      // DLNA sessions need a device description from discovery metadata.
      session = DlnaSession.fromDevice(device);
      await session.connect();
    } else {
      // For Chromecast and AirPlay, CastService.connect() uses the
      // sessionFactory to create the appropriate session.
      session = await castService.connect(device);
    }

    if (context.mounted) Navigator.of(context).pop(); // connecting dialog
    return session;
  } on NeedsPairingException {
    if (context.mounted) Navigator.of(context).pop(); // connecting dialog

    // Trigger PIN display on the TV. Fire-and-forget — show the dialog
    // immediately rather than waiting for the response.
    AirPlayPairSetup(
      host: device.address.address,
      port: device.port,
    ).startPinDisplay();

    if (!context.mounted) return null;
    final pin = await _showPinDialog(context);
    if (pin == null || pin.length != 4 || !context.mounted) return null;

    _showConnectingDialog(context, device.name);
    try {
      // Create a fresh AirPlaySession for pairing, then connect with the
      // newly stored credentials.
      final session = AirPlaySession(device);
      await session.pairSetup(pin);
      await session.connect();

      if (context.mounted) Navigator.of(context).pop(); // connecting dialog
      return session;
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // connecting dialog
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Pairing failed: $e')));
      }
      return null;
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop(); // connecting dialog
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to connect: $e')));
    }
    return null;
  }
}

/// Shows a connecting dialog with a spinner and device name.
void _showConnectingDialog(BuildContext context, String deviceName) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder:
        (_) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 24),
              Expanded(child: Text('Connecting to $deviceName...')),
            ],
          ),
        ),
  );
}

/// Shows a dialog prompting the user to enter the 4-digit AirPlay PIN.
Future<String?> _showPinDialog(BuildContext context) {
  final pinController = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder:
        (dialogContext) => AlertDialog(
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
              onPressed:
                  () => Navigator.of(dialogContext).pop(pinController.text),
              child: const Text('Pair'),
            ),
          ],
        ),
  );
}
