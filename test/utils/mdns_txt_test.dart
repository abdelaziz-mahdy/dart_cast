import 'package:dart_cast/src/utils/mdns_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('MdnsDiscovery.parseTxtRecords (RFC 6763 §6.4)', () {
    test('keys are case-insensitive and the first occurrence wins', () {
      final records = MdnsDiscovery.parseTxtRecords(
        'FN=Living Room\nfn=Second\nId=abc\n',
      );
      expect(records['fn'], 'Living Room');
      expect(records['id'], 'abc');
    });

    test('a key without = is a boolean attribute', () {
      expect(MdnsDiscovery.parseTxtRecords('acl\n'), {'acl': ''});
    });

    test('values are kept exactly, and a leading = is ignored', () {
      final records = MdnsDiscovery.parseTxtRecords(' x= padded \n=junk\n');
      expect(records[' x'], ' padded ');
      expect(records.containsKey(''), isFalse);
    });
  });

  group('MdnsServiceInfo.deviceId', () {
    test('falls back to the instance name when TXT has no id', () {
      const a = MdnsServiceInfo(
        name: 'TV-A._googlecast._tcp.local',
        host: '192.168.1.2',
        port: 8009,
        txtRecords: {},
      );
      const b = MdnsServiceInfo(
        name: 'TV-B._googlecast._tcp.local',
        host: '192.168.1.3',
        port: 8009,
        txtRecords: {},
      );
      expect(a.deviceId, isNot(b.deviceId));
      expect(a.deviceId, isNotEmpty);
    });

    test('prefers the TXT id', () {
      const info = MdnsServiceInfo(
        name: 'TV._googlecast._tcp.local',
        host: '192.168.1.2',
        port: 8009,
        txtRecords: {'id': 'cafe'},
      );
      expect(info.deviceId, 'cafe');
    });
  });
}
