import 'dart:convert';

import 'package:http/http.dart' as http;

class XiaozhiOtaService {
  static const String otaUrl = 'https://api.tenclass.net/xiaozhi/ota/';

  // The Android client has no provisioned eFuse serial/HMAC key, so it uses activation v1.
  Map<String, String> _headers({
    required String deviceId,
    required String clientId,
  }) {
    return {
      'Content-Type': 'application/json',
      'Device-Id': deviceId,
      'Client-Id': clientId,
      'User-Agent': 'xiaozhi-android-client/2.0.0',
      'Accept-Language': 'ru-RU',
      'Activation-Version': '1',
    };
  }

  Future<Map<String, dynamic>> requestConfiguration({
    required String deviceId,
    required String clientId,
  }) async {
    final response = await http
        .post(
          Uri.parse(otaUrl),
          headers: _headers(deviceId: deviceId, clientId: clientId),
          body: jsonEncode({
            'version': 2,
            'language': 'ru-RU',
            'mac_address': deviceId,
            'uuid': clientId,
            'chip_model_name': 'android',
            'application': {
              'name': 'xiaozhi-android-client',
              'version': '2.0.0',
            },
            'board': {
              'type': 'android',
              'name': 'Android',
            },
            'protocol': {
              'features': {
                'mcp': false,
                'mcp_20260728': false,
                'udp_probe': false,
                'aec': false,
                'glyph_push': false,
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw Exception('Сервер XiaoZhi вернул ошибку HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Сервер вернул некорректный ответ OTA');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<int> activate({
    required String deviceId,
    required String clientId,
  }) async {
    final activateUrl = otaUrl.endsWith('/')
        ? '${otaUrl}activate'
        : '$otaUrl/activate';
    final response = await http
        .post(
          Uri.parse(activateUrl),
          headers: _headers(deviceId: deviceId, clientId: clientId),
          body: '{}',
        )
        .timeout(const Duration(seconds: 20));
    return response.statusCode;
  }
}
