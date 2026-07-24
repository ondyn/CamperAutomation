import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'battery_service.dart';

class LiTimeRestServer {
  LiTimeRestServer(this._service);

  final LiTimeBatteryService _service;
  final DateTime _startTime = DateTime.now();
  HttpServer? _server;

  Future<void> start({int port = 8766}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    debugPrint('[LiTimeRestServer] Listening on 127.0.0.1:$port');
    _server!.listen(
      _handleRequest,
      onError: (Object error) =>
          debugPrint('[LiTimeRestServer] Error: $error'),
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers.contentType = ContentType.json;
    if (request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    try {
      switch (request.uri.path) {
        case '/health':
          response.write(jsonEncode(<String, dynamic>{
            'status': 'ok',
            'uptime_seconds':
                DateTime.now().difference(_startTime).inSeconds,
          }));
        case '/api/battery':
        case '/api/litime':
          response.write(jsonEncode(_service.state.toJson()));
        default:
          response.statusCode = HttpStatus.notFound;
          response.write(jsonEncode(<String, dynamic>{'error': 'not found'}));
      }
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode(<String, dynamic>{'error': error.toString()}));
    } finally {
      await response.close();
    }
  }
}
