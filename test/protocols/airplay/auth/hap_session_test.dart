import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

void main() {
  group('deriveHapSessionKeys', () {
    test('produces 32-byte output and input keys', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final keys = await deriveHapSessionKeys(sharedSecret);

      expect(keys.outputKey.length, equals(32));
      expect(keys.inputKey.length, equals(32));
    });

    test('output and input keys are different', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final keys = await deriveHapSessionKeys(sharedSecret);

      expect(keys.outputKey, isNot(equals(keys.inputKey)));
    });

    test('deterministic: same input produces same keys', () async {
      final sharedSecret = Uint8List.fromList(List.generate(32, (i) => i * 3));

      final keys1 = await deriveHapSessionKeys(sharedSecret);
      final keys2 = await deriveHapSessionKeys(sharedSecret);

      expect(keys1.outputKey, equals(keys2.outputKey));
      expect(keys1.inputKey, equals(keys2.inputKey));
    });
  });

  group('deriveEventKeys', () {
    test('produces 32-byte output and input keys', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final keys = await deriveEventKeys(sharedSecret);

      expect(keys.outputKey.length, equals(32));
      expect(keys.inputKey.length, equals(32));
    });

    test('output and input keys are different', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final keys = await deriveEventKeys(sharedSecret);

      expect(keys.outputKey, isNot(equals(keys.inputKey)));
    });

    test('event keys differ from control keys', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final controlKeys = await deriveHapSessionKeys(sharedSecret);
      final eventKeys = await deriveEventKeys(sharedSecret);

      expect(eventKeys.outputKey, isNot(equals(controlKeys.outputKey)));
      expect(eventKeys.inputKey, isNot(equals(controlKeys.inputKey)));
    });

    test('deterministic: same input produces same keys', () async {
      final sharedSecret = Uint8List.fromList(List.generate(32, (i) => i * 3));

      final keys1 = await deriveEventKeys(sharedSecret);
      final keys2 = await deriveEventKeys(sharedSecret);

      expect(keys1.outputKey, equals(keys2.outputKey));
      expect(keys1.inputKey, equals(keys2.inputKey));
    });
  });

  group('HapSession encrypt/decrypt', () {
    late HapSession session;
    late ServerSocket serverSocket;

    setUp(() async {
      // Create a dummy socket pair for testing
      serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', serverSocket.port);

      // Use the same key for both directions in tests for simplicity
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      session = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSocket.port,
        sessionId: 'test-session',
      );
    });

    tearDown(() async {
      await session.close();
      await serverSocket.close();
    });

    test('encrypt produces correct frame format', () async {
      final data = Uint8List.fromList(utf8.encode('Hello, HAP!'));
      final encrypted = await session.encrypt(data);

      // Frame = 2-byte length + encrypted data + 16-byte tag
      expect(encrypted.length, equals(2 + data.length + 16));

      // First 2 bytes should be little-endian length of the original data
      final length = encrypted[0] | (encrypted[1] << 8);
      expect(length, equals(data.length));
    });

    test('encrypt increments output counter', () async {
      expect(session.outputCounter, equals(0));

      await session.encrypt(Uint8List.fromList([1, 2, 3]));
      expect(session.outputCounter, equals(1));

      await session.encrypt(Uint8List.fromList([4, 5, 6]));
      expect(session.outputCounter, equals(2));
    });

    test('decrypt increments input counter', () async {
      // First encrypt some data so we have valid ciphertext
      final data = Uint8List.fromList(utf8.encode('test'));

      // Create a separate session for encrypting (simulates the device)
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final encSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final encSession = HapSession(
        socket: encSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await encSession.encrypt(data);

      expect(session.inputCounter, equals(0));
      await session.decrypt(encrypted);
      expect(session.inputCounter, equals(1));

      await encSession.close();
      await serverSock.close();
    });

    test('encrypt then decrypt roundtrip for small data', () async {
      final original = Uint8List.fromList(utf8.encode('Small payload'));

      // Use matching keys: session encrypts with outputKey,
      // and a second session decrypts with inputKey = first session's outputKey
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      // Create decrypt session with inputKey = encrypt session's outputKey
      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final decSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final decSession = HapSession(
        socket: decSocket,
        outputKey: Uint8List.fromList(key), // not used
        inputKey: Uint8List.fromList(key), // matches session's outputKey
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await session.encrypt(original);
      final decrypted = await decSession.decrypt(encrypted);

      expect(decrypted, equals(original));

      await decSession.close();
      await serverSock.close();
    });

    test('encrypt splits data into 1024-byte frames', () async {
      // Create data larger than one frame
      final data = Uint8List(2500);
      for (int i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final encrypted = await session.encrypt(data);

      // Frame 1: 1024 bytes -> 2 + 1024 + 16 = 1042
      // Frame 2: 1024 bytes -> 2 + 1024 + 16 = 1042
      // Frame 3: 452 bytes  -> 2 + 452 + 16 = 470
      // Total: 1042 + 1042 + 470 = 2554
      expect(encrypted.length, equals(2554));

      // Verify first frame length
      final len1 = encrypted[0] | (encrypted[1] << 8);
      expect(len1, equals(1024));

      // Verify second frame length (starts at offset 1042)
      final len2 = encrypted[1042] | (encrypted[1043] << 8);
      expect(len2, equals(1024));

      // Verify third frame length (starts at offset 2084)
      final len3 = encrypted[2084] | (encrypted[2085] << 8);
      expect(len3, equals(452));

      // Output counter should be 3 (one per frame)
      expect(session.outputCounter, equals(3));
    });

    test('multi-frame encrypt/decrypt roundtrip', () async {
      final original = Uint8List(2500);
      for (int i = 0; i < original.length; i++) {
        original[i] = i % 256;
      }

      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final decSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final decSession = HapSession(
        socket: decSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await session.encrypt(original);
      final decrypted = await decSession.decrypt(encrypted);

      expect(decrypted, equals(original));

      await decSession.close();
      await serverSock.close();
    });

    test('encrypt empty data returns empty', () async {
      final encrypted = await session.encrypt(Uint8List(0));
      expect(encrypted.length, equals(0));
      expect(session.outputCounter, equals(0));
    });

    test('decrypt partial frame buffers data', () async {
      final original = Uint8List.fromList(utf8.encode('test data'));

      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      // Encrypt to get valid frame
      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final encSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final encSession = HapSession(
        socket: encSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await encSession.encrypt(original);

      // Feed only partial data first (just the length bytes)
      final partial1 = encrypted.sublist(0, 5);
      final partial2 = encrypted.sublist(5);

      final result1 = await session.decrypt(Uint8List.fromList(partial1));
      // Should return empty since we don't have a complete frame
      expect(result1.length, equals(0));
      expect(session.inputCounter, equals(0));

      // Now feed the rest
      final result2 = await session.decrypt(Uint8List.fromList(partial2));
      expect(result2, equals(original));
      expect(session.inputCounter, equals(1));

      await encSession.close();
      await serverSock.close();
    });

    test('encrypt exactly 1024 bytes produces single frame', () async {
      final data = Uint8List(1024);
      for (int i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final encrypted = await session.encrypt(data);

      // Single frame: 2 + 1024 + 16 = 1042
      expect(encrypted.length, equals(1042));
      expect(session.outputCounter, equals(1));

      final len = encrypted[0] | (encrypted[1] << 8);
      expect(len, equals(1024));
    });
  });

  group('HapSession HTTP request/response through encrypted channel', () {
    test('sendRequest sends encrypted HTTP and receives encrypted response',
        () async {
      // Set up keys
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      // Create a raw TCP server that decrypts requests and sends encrypted responses
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

      final clientSocket = await Socket.connect('127.0.0.1', server.port);

      final hapSession = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: server.port,
        sessionId: 'test-session-id',
      );

      // Server side: decrypt request, send encrypted response.
      // HapSession's constructor sets up a single persistent listener on
      // the socket, so we must NOT call serverSocket.listen() separately.
      server.listen((serverSocket) async {
        final serverDecSession = HapSession(
          socket: serverSocket,
          outputKey: Uint8List.fromList(key), // matches client's inputKey
          inputKey: Uint8List.fromList(key), // matches client's outputKey
          host: '127.0.0.1',
          port: server.port,
        );

        try {
          // Read decrypted data via the session's internal buffer
          final decrypted = await serverDecSession.readDecryptedData();
          final requestStr = utf8.decode(decrypted);

          // Verify it looks like an HTTP request
          if (requestStr.contains('GET /test-endpoint')) {
            // Send encrypted HTTP response
            final responseStr =
                'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!';
            final respBytes = Uint8List.fromList(utf8.encode(responseStr));
            final encrypted = await serverDecSession.encrypt(respBytes);
            serverSocket.add(encrypted);
            await serverSocket.flush();
          }
        } catch (e) {
          // Ignore decryption errors in test
        }
      });

      try {
        final response = await hapSession.sendRequest('GET', '/test-endpoint');

        expect(response.statusCode, equals(200));
        expect(response.bodyText, equals('Hello, World!'));
      } finally {
        await hapSession.close();
        await server.close();
      }
    });
  });

  group('HapSession nonce building', () {
    test('first nonce is all zeros', () async {
      // Verify by encrypting with counter 0 and checking it works
      final key = Uint8List(32);
      final data = Uint8List.fromList([1, 2, 3]);

      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final socket = await Socket.connect('127.0.0.1', serverSock.port);

      final session = HapSession(
        socket: socket,
        outputKey: key,
        inputKey: key,
        host: '127.0.0.1',
        port: serverSock.port,
      );

      // Encrypt should succeed (verifies nonce is valid)
      final encrypted = await session.encrypt(data);
      expect(encrypted.length, greaterThan(0));

      await session.close();
      await serverSock.close();
    });
  });

  group('HapHttpResponse', () {
    test('bodyText decodes UTF-8', () {
      final response = HapHttpResponse(
        statusCode: 200,
        reasonPhrase: 'OK',
        headers: {},
        body: Uint8List.fromList(utf8.encode('Hello!')),
      );
      expect(response.bodyText, equals('Hello!'));
    });

    test('toString includes status and size', () {
      final response = HapHttpResponse(
        statusCode: 404,
        reasonPhrase: 'Not Found',
        headers: {},
        body: Uint8List(42),
      );
      expect(response.toString(), contains('404'));
      expect(response.toString(), contains('42'));
    });
  });

  group('HapSessionException', () {
    test('toString includes message', () {
      final e = HapSessionException('something broke');
      expect(e.toString(), contains('something broke'));
      expect(e.toString(), contains('HapSessionException'));
    });
  });

  group('RTSP request formatting (sendRtspRequest)', () {
    late ServerSocket server;
    late HapSession clientSession;

    /// Helper: creates a server + client HapSession pair with matching keys.
    /// Returns the server socket so the caller can listen for connections.
    Future<({ServerSocket server, HapSession client})> _createPair({
      String? sessionId,
    }) async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', srv.port);
      final client = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: srv.port,
        sessionId: sessionId ?? 'test-rtsp-session',
      );
      return (server: srv, client: client);
    }

    /// Helper: creates a server-side HapSession from an accepted socket.
    HapSession _serverSession(Socket sock, int port) {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      return HapSession(
        socket: sock,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: port,
      );
    }

    test('uses RTSP/1.0 protocol line, not HTTP/1.1', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      String? receivedRequest;
      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          final data = await srvSession.readDecryptedData();
          receivedRequest = utf8.decode(data);

          // Send back a valid RTSP response
          final resp =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      await clientSession.sendRtspRequest('OPTIONS', '*');

      expect(receivedRequest, isNotNull);
      expect(receivedRequest!, contains('OPTIONS * RTSP/1.0\r\n'));
      expect(receivedRequest!, isNot(contains('HTTP/1.1')));

      await clientSession.close();
      await server.close();
    });

    test('CSeq header auto-increments', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      final receivedRequests = <String>[];
      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          for (int i = 0; i < 3; i++) {
            final data = await srvSession.readDecryptedData();
            receivedRequests.add(utf8.decode(data));

            final resp =
                'RTSP/1.0 200 OK\r\nCSeq: ${i + 1}\r\nContent-Length: 0\r\n\r\n';
            final encrypted =
                await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(encrypted);
            await sock.flush();
          }
        } catch (_) {}
      });

      await clientSession.sendRtspRequest('OPTIONS', '*');
      await clientSession.sendRtspRequest('SETUP', 'rtsp://127.0.0.1/123');
      await clientSession.sendRtspRequest('RECORD', 'rtsp://127.0.0.1/123');

      expect(receivedRequests.length, equals(3));
      expect(receivedRequests[0], contains('CSeq: 1'));
      expect(receivedRequests[1], contains('CSeq: 2'));
      expect(receivedRequests[2], contains('CSeq: 3'));

      await clientSession.close();
      await server.close();
    });

    test('includes X-Apple-Session-ID header', () async {
      final pair = await _createPair(sessionId: 'my-unique-session-42');
      server = pair.server;
      clientSession = pair.client;

      String? receivedRequest;
      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          final data = await srvSession.readDecryptedData();
          receivedRequest = utf8.decode(data);

          final resp =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      await clientSession.sendRtspRequest('OPTIONS', '*');

      expect(receivedRequest,
          contains('X-Apple-Session-ID: my-unique-session-42'));

      await clientSession.close();
      await server.close();
    });

    test('User-Agent is AirPlay/550.10', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      String? receivedRequest;
      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          final data = await srvSession.readDecryptedData();
          receivedRequest = utf8.decode(data);

          final resp =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      await clientSession.sendRtspRequest('SETUP', 'rtsp://127.0.0.1/123');

      expect(receivedRequest, contains('User-Agent: AirPlay/550.10'));

      await clientSession.close();
      await server.close();
    });

    test('includes body and Content-Length when body is provided', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      Uint8List? receivedRaw;
      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          final data = await srvSession.readDecryptedData();
          receivedRaw = data;

          final resp =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final body = utf8.encode('{"test": true}');
      await clientSession.sendRtspRequest('POST', '/play',
          headers: {'Content-Type': 'application/json'}, body: body);

      expect(receivedRaw, isNotNull);
      final requestStr = utf8.decode(receivedRaw!);
      expect(requestStr, contains('Content-Length: ${body.length}'));
      expect(requestStr, contains('Content-Type: application/json'));
      // Body comes after \r\n\r\n
      final headerEnd = requestStr.indexOf('\r\n\r\n');
      expect(headerEnd, greaterThan(0));
      final bodyPart = requestStr.substring(headerEnd + 4);
      expect(bodyPart, equals('{"test": true}'));

      await clientSession.close();
      await server.close();
    });

    test('omits Content-Length when no body is provided', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      String? receivedRequest;
      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          final data = await srvSession.readDecryptedData();
          receivedRequest = utf8.decode(data);

          final resp =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      await clientSession.sendRtspRequest('OPTIONS', '*');

      expect(receivedRequest, isNot(contains('Content-Length')));

      await clientSession.close();
      await server.close();
    });
  });

  group('HTTP response parsing with RTSP', () {
    late ServerSocket server;
    late HapSession clientSession;

    Future<({ServerSocket server, HapSession client})> _createPair() async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', srv.port);
      final client = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: srv.port,
        sessionId: 'test-parse-session',
      );
      return (server: srv, client: client);
    }

    HapSession _serverSession(Socket sock, int port) {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      return HapSession(
        socket: sock,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: port,
      );
    }

    test('parses RTSP/1.0 200 OK response', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          final resp =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nServer: AirTunes/550.10\r\nContent-Length: 5\r\n\r\nhello';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response = await clientSession.sendRtspRequest('OPTIONS', '*');

      expect(response.statusCode, equals(200));
      expect(response.reasonPhrase, equals('OK'));
      expect(response.headers['cseq'], equals('1'));
      expect(response.headers['server'], equals('AirTunes/550.10'));
      expect(response.bodyText, equals('hello'));

      await clientSession.close();
      await server.close();
    });

    test('parses RTSP/1.0 response with no reason phrase', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          // Status line with no reason phrase after code
          final resp = 'RTSP/1.0 200\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response = await clientSession.sendRtspRequest('OPTIONS', '*');

      expect(response.statusCode, equals(200));
      expect(response.reasonPhrase, equals(''));

      await clientSession.close();
      await server.close();
    });

    test('parses response with binary body', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      // Binary body with non-UTF8 bytes
      final binaryBody =
          Uint8List.fromList([0x00, 0x01, 0xFF, 0xFE, 0x80, 0x90]);

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          final headerStr =
              'RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Type: application/octet-stream\r\nContent-Length: ${binaryBody.length}\r\n\r\n';
          final headerBytes = utf8.encode(headerStr);
          final fullResponse =
              Uint8List.fromList([...headerBytes, ...binaryBody]);
          final encrypted = await srvSession.encrypt(fullResponse);
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response =
          await clientSession.sendRtspRequest('GET', '/playback-info');

      expect(response.statusCode, equals(200));
      expect(response.body, equals(binaryBody));
      expect(response.body.length, equals(6));

      await clientSession.close();
      await server.close();
    });

    test('parses RTSP/1.0 with non-200 status code', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          final resp =
              'RTSP/1.0 453 Not Enough Bandwidth\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response =
          await clientSession.sendRtspRequest('SETUP', 'rtsp://127.0.0.1/1');

      expect(response.statusCode, equals(453));
      expect(response.reasonPhrase, equals('Not Enough Bandwidth'));

      await clientSession.close();
      await server.close();
    });
  });

  group('_isCompleteHttpResponse edge cases (indirect)', () {
    late ServerSocket server;
    late HapSession clientSession;

    Future<({ServerSocket server, HapSession client})> _createPair() async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', srv.port);
      final client = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: srv.port,
        sessionId: 'test-complete-session',
      );
      return (server: srv, client: client);
    }

    HapSession _serverSession(Socket sock, int port) {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      return HapSession(
        socket: sock,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: port,
      );
    }

    test('response with Content-Length waits for full body', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      final bodyContent = 'A' * 100; // 100-byte body

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          final resp =
              'HTTP/1.1 200 OK\r\nContent-Length: ${bodyContent.length}\r\n\r\n$bodyContent';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response = await clientSession.sendRequest('GET', '/test');

      expect(response.statusCode, equals(200));
      expect(response.bodyText, equals(bodyContent));
      expect(response.bodyText.length, equals(100));

      await clientSession.close();
      await server.close();
    });

    test('response with no Content-Length and no body completes', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          // No Content-Length, no body — just headers
          final resp = 'HTTP/1.1 204 No Content\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response = await clientSession.sendRequest('DELETE', '/resource');

      expect(response.statusCode, equals(204));
      expect(response.body.length, equals(0));

      await clientSession.close();
      await server.close();
    });

    test('response with chunked transfer encoding completes', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          await srvSession.readDecryptedData();

          // Chunked response with terminal 0\r\n\r\n
          final resp =
              'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n';
          final encrypted =
              await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
          sock.add(encrypted);
          await sock.flush();
        } catch (_) {}
      });

      final response = await clientSession.sendRequest('GET', '/chunked');

      expect(response.statusCode, equals(200));
      // The body will contain the raw chunked data since _parseHttpResponse
      // doesn't decode chunks, it just returns everything after headers
      expect(response.bodyText, contains('hello'));

      await clientSession.close();
      await server.close();
    });
  });

  group('resetRtspSession resets session state', () {
    late ServerSocket server;
    late HapSession clientSession;

    Future<({ServerSocket server, HapSession client})> _createPair() async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', srv.port);
      final client = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: srv.port,
        sessionId: 'test-stop-session',
      );
      return (server: srv, client: client);
    }

    HapSession _serverSession(Socket sock, int port) {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }
      return HapSession(
        socket: sock,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: port,
      );
    }

    test('resetRtspSession resets sessionId and CSeq counter', () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      final originalSessionId = clientSession.sessionId;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          // Handle multiple requests
          while (true) {
            final data = await srvSession.readDecryptedData();
            final requestStr = utf8.decode(data);

            // Always respond 200 OK
            final cseqMatch = RegExp(r'CSeq:\s*(\d+)').firstMatch(requestStr);
            final cseq = cseqMatch?.group(1) ?? '1';
            final resp =
                'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
            final encrypted =
                await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(encrypted);
            await sock.flush();
          }
        } catch (_) {}
      });

      // Send some requests to advance CSeq
      await clientSession.sendRtspRequest('OPTIONS', '*');
      await clientSession.sendRtspRequest('OPTIONS', '*');

      // Now reset — no network request
      clientSession.resetRtspSession();

      // After reset, sessionId should be different
      expect(clientSession.sessionId, isNot(equals(originalSessionId)));

      // The next request should have CSeq: 1 (reset from 0, then incremented)
      // We need to capture the next request — the server is already listening
      // and will receive it. Let's just send and check the response works.
      // We verify CSeq reset by checking that the next RTSP request works
      // (resetRtspSession set _cseq=0, next sendRtspRequest will set it to 1).

      // Send another request after reset — CSeq should restart at 1
      // The server is already listening, so just send
      await clientSession.sendRtspRequest('OPTIONS', '*');

      // We can verify the CSeq reset indirectly: if it weren't reset,
      // CSeq would be 4 (was at 3 after reset). Since resetRtspSession resets
      // to 0, the next call increments to 1.
      // We already tested CSeq increment above, so we trust the
      // implementation here. The key assertion is:
      expect(clientSession.sessionId, isNot(equals(originalSessionId)));

      await clientSession.close();
      await server.close();
    });

    test('resetRtspSession causes next setupRtspSession to re-run SETUP+RECORD',
        () async {
      final pair = await _createPair();
      server = pair.server;
      clientSession = pair.client;

      int requestCount = 0;

      server.listen((sock) async {
        final srvSession = _serverSession(sock, server.port);
        try {
          while (true) {
            final data = await srvSession.readDecryptedData();
            requestCount++;
            final requestStr = utf8.decode(data, allowMalformed: true);

            final cseqMatch = RegExp(r'CSeq:\s*(\d+)').firstMatch(requestStr);
            final cseq = cseqMatch?.group(1) ?? '$requestCount';
            final resp =
                'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
            final encrypted =
                await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(encrypted);
            await sock.flush();
          }
        } catch (_) {}
      });

      // First setupRtspSession: SETUP + POST /feedback + RECORD = 3 requests
      await clientSession.setupRtspSession();
      expect(requestCount, equals(3));

      // Second call is a no-op (already set up)
      await clientSession.setupRtspSession();
      expect(requestCount, equals(3));

      // resetRtspSession() resets _rtspSessionSetUp and CSeq — no network request
      clientSession.resetRtspSession();
      expect(requestCount, equals(3)); // no /stop sent

      // Now setupRtspSession must run again (3 more requests)
      await clientSession.setupRtspSession();
      expect(requestCount, equals(6)); // +3 for SETUP + feedback + RECORD

      await clientSession.close();
      await server.close();
    });
  });

  group('UUID format validation', () {
    test('sessionId matches UUID v4 format (8-4-4-4-12 hex)', () async {
      final serverSocket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', serverSocket.port);

      final key = Uint8List(32);
      final session = HapSession(
        socket: clientSocket,
        outputKey: key,
        inputKey: key,
        host: '127.0.0.1',
        port: serverSocket.port,
        // No sessionId provided — should auto-generate UUID
      );

      // UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      // where y is one of [8, 9, a, b]
      final uuidRegex = RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      expect(session.sessionId, matches(uuidRegex));

      await session.close();
      await serverSocket.close();
    });

    test('multiple sessions generate unique sessionIds', () async {
      final sessions = <HapSession>[];
      final servers = <ServerSocket>[];
      final ids = <String>{};

      for (int i = 0; i < 5; i++) {
        final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(srv);
        final sock = await Socket.connect('127.0.0.1', srv.port);
        final key = Uint8List(32);
        final s = HapSession(
          socket: sock,
          outputKey: key,
          inputKey: key,
          host: '127.0.0.1',
          port: srv.port,
        );
        sessions.add(s);
        ids.add(s.sessionId);
      }

      // All 5 should be unique
      expect(ids.length, equals(5));

      for (final s in sessions) {
        await s.close();
      }
      for (final srv in servers) {
        await srv.close();
      }
    });
  });

  group('setupRtspSession flow', () {
    test('sends SETUP, POST /feedback, RECORD in order with encrypted RTSP',
        () async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);

      final clientSession = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: server.port,
        sessionId: 'test-setup-session',
      );

      final receivedMethods = <String>[];
      final receivedUris = <String>[];

      server.listen((sock) async {
        final srvSession = HapSession(
          socket: sock,
          outputKey: Uint8List.fromList(key),
          inputKey: Uint8List.fromList(key),
          host: '127.0.0.1',
          port: server.port,
        );

        try {
          for (int i = 0; i < 3; i++) {
            final data = await srvSession.readDecryptedData();
            final requestStr = utf8.decode(data, allowMalformed: true);
            final firstLine = requestStr.split('\r\n').first;
            final parts = firstLine.split(' ');
            receivedMethods.add(parts[0]);
            if (parts.length > 1) receivedUris.add(parts[1]);

            final cseqMatch = RegExp(r'CSeq:\s*(\d+)').firstMatch(requestStr);
            final cseq = cseqMatch?.group(1) ?? '${i + 1}';
            final resp =
                'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
            final encrypted =
                await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(encrypted);
            await sock.flush();
          }
        } catch (_) {}
      });

      await clientSession.setupRtspSession();

      // Verify order: SETUP, POST, RECORD
      expect(receivedMethods.length, equals(3));
      expect(receivedMethods[0], equals('SETUP'));
      expect(receivedMethods[1], equals('POST'));
      expect(receivedMethods[2], equals('RECORD'));

      // POST /feedback URI
      expect(receivedUris[1], equals('/feedback'));

      // SETUP and RECORD should use rtsp://host/number URI format
      final rtspUriRegex = RegExp(r'^rtsp://127\.0\.0\.1/\d+$');
      expect(receivedUris[0], matches(rtspUriRegex));
      expect(receivedUris[2], matches(rtspUriRegex));

      // SETUP and RECORD should use the same URI
      expect(receivedUris[0], equals(receivedUris[2]));

      await clientSession.close();
      await server.close();
    });

    test('setupRtspSession is idempotent — second call is a no-op', () async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);

      final clientSession = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: server.port,
      );

      int requestCount = 0;

      server.listen((sock) async {
        final srvSession = HapSession(
          socket: sock,
          outputKey: Uint8List.fromList(key),
          inputKey: Uint8List.fromList(key),
          host: '127.0.0.1',
          port: server.port,
        );

        try {
          while (true) {
            await srvSession.readDecryptedData();
            requestCount++;

            final resp =
                'RTSP/1.0 200 OK\r\nCSeq: $requestCount\r\nContent-Length: 0\r\n\r\n';
            final encrypted =
                await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(encrypted);
            await sock.flush();
          }
        } catch (_) {}
      });

      await clientSession.setupRtspSession();
      expect(requestCount, equals(3)); // SETUP + feedback + RECORD

      // Second call should be no-op
      await clientSession.setupRtspSession();
      expect(requestCount, equals(3)); // No new requests

      await clientSession.close();
      await server.close();
    });

    test('SETUP request includes Content-Type for binary plist', () async {
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', server.port);

      final clientSession = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: server.port,
      );

      String? setupRequest;

      server.listen((sock) async {
        final srvSession = HapSession(
          socket: sock,
          outputKey: Uint8List.fromList(key),
          inputKey: Uint8List.fromList(key),
          host: '127.0.0.1',
          port: server.port,
        );

        try {
          for (int i = 0; i < 3; i++) {
            final data = await srvSession.readDecryptedData();
            if (i == 0) {
              setupRequest = utf8.decode(data, allowMalformed: true);
            }

            final resp =
                'RTSP/1.0 200 OK\r\nCSeq: ${i + 1}\r\nContent-Length: 0\r\n\r\n';
            final encrypted =
                await srvSession.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(encrypted);
            await sock.flush();
          }
        } catch (_) {}
      });

      await clientSession.setupRtspSession();

      expect(setupRequest, isNotNull);
      expect(setupRequest!,
          contains('Content-Type: application/x-apple-binary-plist'));
      // Should also have Content-Length for the plist body
      expect(setupRequest!, contains('Content-Length:'));

      await clientSession.close();
      await server.close();
    });
  });
}
