import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'charger_service.dart';

/// Minimal HTTP server bound to 127.0.0.1:8765.
/// Exposes GET /health and GET /api/charger.
/// Only accessible from the local device — never binds to a network interface.
class ChargerRestServer {
  ChargerRestServer(this._service);

  final ChargerService _service;
  final DateTime _startTime = DateTime.now();
  HttpServer? _server;

  Future<void> start({int port = 8765}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    debugPrint('[RestServer] Listening on 127.0.0.1:$port');
    _server!.listen(
      _handleRequest,
      onError: (Object e) => debugPrint('[RestServer] Error: $e'),
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final HttpResponse res = req.response;
    res.headers.contentType = ContentType.json;
    // Restrict to GET only.
    if (req.method != 'GET') {
      res.statusCode = HttpStatus.methodNotAllowed;
      await res.close();
      return;
    }
    try {
      switch (req.uri.path) {
        case '/health':
          final int uptime = DateTime.now().difference(_startTime).inSeconds;
          res.write(jsonEncode(<String, dynamic>{
            'status': 'ok',
            'uptime_seconds': uptime,
          }));
        case '/api/charger':
          res.write(jsonEncode(_service.state.toJson()));
        default:
          res.statusCode = HttpStatus.notFound;
          res.write(jsonEncode(<String, dynamic>{'error': 'not found'}));
      }
    } catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      res.write(jsonEncode(<String, dynamic>{'error': e.toString()}));
    } finally {
      await res.close();
    }
  }
}
