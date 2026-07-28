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

    try {
      switch ((request.method, request.uri.path)) {
        case ('GET', '/health'):
          response.write(jsonEncode(<String, dynamic>{
            'status': 'ok',
            'uptime_seconds':
                DateTime.now().difference(_startTime).inSeconds,
          }));
        case ('GET', '/api/battery'):
        case ('GET', '/api/litime'):
          response.write(jsonEncode(_service.state.toJson()));
        case ('POST', '/api/battery/discharge'):
          final Map<String, dynamic> body = await _readJsonBody(request);
          final Object? enabled = body['enabled'];
          if (enabled is! bool) {
            throw const FormatException('enabled must be a boolean');
          }
          await _service.setDischargeEnabled(enabled);
          response.write(jsonEncode(<String, dynamic>{
            'status': 'accepted',
            'discharge_enabled': enabled,
          }));
        case ('POST', '/api/battery/power-off'):
          final Map<String, dynamic> body = await _readJsonBody(request);
          if (body['confirm'] != true) {
            throw const FormatException('confirm must be true');
          }
          await _service.shutdown();
          response.write(jsonEncode(<String, dynamic>{'status': 'powered_off'}));
        default:
          response.statusCode = request.method == 'GET' || request.method == 'POST'
              ? HttpStatus.notFound
              : HttpStatus.methodNotAllowed;
          response.write(jsonEncode(<String, dynamic>{'error': 'not found'}));
      }
    } on FormatException catch (error) {
      response.statusCode = HttpStatus.badRequest;
      response.write(jsonEncode(<String, dynamic>{'error': error.message}));
    } on StateError catch (error) {
      response.statusCode = HttpStatus.conflict;
      response.write(jsonEncode(<String, dynamic>{'error': error.message}));
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode(<String, dynamic>{'error': error.toString()}));
    } finally {
      await response.close();
    }
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    final Object? value = jsonDecode(await utf8.decoder.bind(request).join());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('request body must be a JSON object');
    }
    return value;
  }
}
