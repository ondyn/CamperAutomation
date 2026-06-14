import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'obd_service.dart';

/// Minimal HTTP server bound to 127.0.0.1:8766.
///
/// Exposes:
///   GET  /health             → uptime check
///   GET  /api/obd            → full OBD state snapshot
///   POST /api/obd/command    → trigger OBD commands (e.g. clear DTCs)
///
/// Only accessible from the local device (loopback) — never binds to
/// a network interface.  Home Assistant in Termux accesses this via
/// http://127.0.0.1:8766/.
class OBDRestServer {
  OBDRestServer(this._service);

  final OBDService _service;
  final DateTime _startTime = DateTime.now();
  HttpServer? _server;

  Future<void> start({int port = 8766}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    debugPrint('[OBDRestServer] Listening on 127.0.0.1:$port');
    _server!.listen(
      _handleRequest,
      onError: (Object e) => debugPrint('[OBDRestServer] error: $e'),
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final HttpResponse res = req.response;
    res.headers.contentType = ContentType.json;
    // CORS: only same-device access expected; block cross-origin for safety.
    res.headers.set('Access-Control-Allow-Origin', 'null');

    try {
      switch (req.method) {
        case 'GET':
          await _handleGet(req, res);
        case 'POST':
          await _handlePost(req, res);
        default:
          res.statusCode = HttpStatus.methodNotAllowed;
          res.write(jsonEncode(<String, dynamic>{'error': 'method not allowed'}));
      }
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      res.write(jsonEncode(<String, dynamic>{'error': e.toString()}));
    } finally {
      await res.close();
    }
  }

  Future<void> _handleGet(HttpRequest req, HttpResponse res) async {
    switch (req.uri.path) {
      case '/health':
        final int uptime = DateTime.now().difference(_startTime).inSeconds;
        res.write(jsonEncode(<String, dynamic>{
          'status': 'ok',
          'uptime_seconds': uptime,
        }));

      case '/api/obd':
        res.write(jsonEncode(_service.state.toJson()));

      default:
        res.statusCode = HttpStatus.notFound;
        res.write(jsonEncode(<String, dynamic>{'error': 'not found'}));
    }
  }

  Future<void> _handlePost(HttpRequest req, HttpResponse res) async {
    if (req.uri.path != '/api/obd/command') {
      res.statusCode = HttpStatus.notFound;
      res.write(jsonEncode(<String, dynamic>{'error': 'not found'}));
      return;
    }

    final String body = await utf8.decodeStream(req);
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
      res.write(jsonEncode(<String, dynamic>{'error': 'invalid JSON'}));
      return;
    }

    final String? command = payload['command'] as String?;
    switch (command) {
      case 'clear_dtcs':
        await _service.clearDtcs();
        res.write(jsonEncode(<String, dynamic>{'status': 'ok'}));

      default:
        res.statusCode = HttpStatus.badRequest;
        res.write(jsonEncode(<String, dynamic>{
          'error': 'unknown command: $command',
        }));
    }
  }
}
