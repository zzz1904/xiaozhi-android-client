import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// A Dreamehome vacuum visible to the signed-in account.
class DreameDevice {
  final String id;
  final String model;
  final String name;
  final bool online;

  const DreameDevice({
    required this.id,
    required this.model,
    required this.name,
    required this.online,
  });

  factory DreameDevice.fromJson(Map<String, dynamic> json) {
    final id = (json['did'] ?? '').toString();
    final model = (json['model'] ?? '').toString();
    final name = (json['customName'] ?? json['deviceName'] ?? model).toString();
    final property = json['property'];
    var lwt = json['lwt'];
    if (property is String) {
      try {
        lwt = (jsonDecode(property) as Map<String, dynamic>)['lwt'] ?? lwt;
      } catch (_) {
        // Some firmware versions return a non-JSON property field.
      }
    }
    return DreameDevice(
      id: id,
      model: model,
      name: name.isEmpty ? id : name,
      online: json['online'] == true || lwt == 1,
    );
  }
}

/// A saved quick-cleaning routine created in the Dreamehome app.
class DreameShortcut {
  final int id;
  final String name;

  const DreameShortcut({required this.id, required this.name});
}

/// Direct Dreamehome cloud client.
///
/// Credentials and refresh tokens are kept in Android Keystore-backed secure
/// storage. No account password or token is written to SharedPreferences/logs.
class DreameService {
  DreameService({
    FlutterSecureStorage? storage,
    http.Client? client,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _client = client ?? http.Client();

  static const _passwordSalt = 'RAylYC%fmSKp7%Tq';
  static const _rlcKey = 'EETjszu*XI5znHsI';
  static const _oauthAuthorization =
      'Basic ZHJlYW1lX2FwcHYxOkFQXmR2QHpAU1FZVnhOODg=';
  static const _appMeta = 'cv=i_829';
  static const _commandFrom = 'XXXXXX';
  static const _tenantId = '000000';

  final FlutterSecureStorage _storage;
  final http.Client _client;

  String _region = 'eu';
  String _country = 'TR';
  String _language = 'ru';
  String? _email;
  String? _password;
  String? _accessToken;
  String? _refreshToken;
  String? _uid;
  DateTime? _expiresAt;

  String get _host => '${_region}.iot.dreame.tech:13267';
  String get _baseUrl => 'https://$_host';

  Future<Map<String, String>> loadSavedSettings() async {
    return {
      'email': await _storage.read(key: 'dreame.email') ?? '',
      'password': await _storage.read(key: 'dreame.password') ?? '',
      'region': await _storage.read(key: 'dreame.region') ?? 'eu',
      'country': await _storage.read(key: 'dreame.country') ?? 'TR',
      'language': await _storage.read(key: 'dreame.language') ?? 'ru',
    };
  }

  Future<void> connect({
    required String email,
    required String password,
    required String region,
    required String country,
    required String language,
  }) async {
    _email = email.trim();
    _password = password;
    _region = region.toLowerCase();
    _country = country.trim().toUpperCase();
    _language = language.trim().toLowerCase();

    if (_email!.isEmpty || _password!.isEmpty) {
      throw DreameException('Введите логин и пароль Dreamehome.');
    }
    if (!const ['eu', 'us', 'cn', 'ru', 'sg', 'in'].contains(_region)) {
      throw DreameException('Неизвестный регион Dreamehome.');
    }

    await _login();
    await _storage.write(key: 'dreame.email', value: _email);
    await _storage.write(key: 'dreame.password', value: _password);
    await _storage.write(key: 'dreame.region', value: _region);
    await _storage.write(key: 'dreame.country', value: _country);
    await _storage.write(key: 'dreame.language', value: _language);
  }

  Future<void> restoreSession() async {
    final saved = await loadSavedSettings();
    _email = saved['email'];
    _password = saved['password'];
    _region = saved['region'] ?? 'eu';
    _country = saved['country'] ?? 'TR';
    _language = saved['language'] ?? 'ru';
    _refreshToken = await _storage.read(key: 'dreame.refreshToken');
    _accessToken = await _storage.read(key: 'dreame.accessToken');
    _uid = await _storage.read(key: 'dreame.uid');
    final expiry = await _storage.read(key: 'dreame.expiresAt');
    _expiresAt = expiry == null ? null : DateTime.tryParse(expiry);
  }

  Future<void> disconnect() async {
    _accessToken = null;
    _refreshToken = null;
    _uid = null;
    _expiresAt = null;
    for (final key in [
      'dreame.email',
      'dreame.password',
      'dreame.region',
      'dreame.country',
      'dreame.language',
      'dreame.accessToken',
      'dreame.refreshToken',
      'dreame.uid',
      'dreame.expiresAt',
    ]) {
      await _storage.delete(key: key);
    }
  }

  Future<void> _login() async {
    final digest = crypto.md5.convert(utf8.encode('$_password$_passwordSalt'));
    final form = {
      'grant_type': 'password',
      'scope': 'all',
      'platform': 'IOS',
      'type': 'account',
      'username': _email!,
      'password': digest.toString(),
      'country': _country,
      'lang': _language,
    };
    await _requestToken(form);
  }

  Future<void> _refresh() async {
    final token = _refreshToken;
    if (token == null || token.isEmpty) {
      await _login();
      return;
    }
    await _requestToken({
      'grant_type': 'refresh_token',
      'refresh_token': token,
    });
  }

  Future<void> _requestToken(Map<String, String> form) async {
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/dreame-auth/oauth/token'),
          headers: _headers(contentType: 'application/x-www-form-urlencoded'),
          body: form,
        )
        .timeout(const Duration(seconds: 25));
    final data = _decodeResponse(response);
    final access = data['access_token']?.toString();
    if (access == null || access.isEmpty) {
      final description = data['error_description'] ?? data['msg'] ?? data['error'];
      throw DreameException(
        'Dreamehome не выдал токен авторизации'
        '${description == null ? '.' : ': $description'}',
      );
    }
    _accessToken = access;
    _refreshToken = data['refresh_token']?.toString() ?? _refreshToken;
    _uid = data['uid']?.toString();
    final seconds = int.tryParse(data['expires_in']?.toString() ?? '') ?? 7200;
    _expiresAt = DateTime.now().add(Duration(seconds: seconds));
    await _storage.write(key: 'dreame.accessToken', value: _accessToken);
    if (_refreshToken != null) {
      await _storage.write(key: 'dreame.refreshToken', value: _refreshToken);
    }
    if (_uid != null) await _storage.write(key: 'dreame.uid', value: _uid);
    await _storage.write(
      key: 'dreame.expiresAt',
      value: _expiresAt!.toIso8601String(),
    );
  }

  Future<void> _ensureSession() async {
    if (_accessToken == null) await restoreSession();
    if (_accessToken == null) {
      if (_email == null || _email!.isEmpty || _password == null || _password!.isEmpty) {
        throw DreameException('Сначала подключите аккаунт Dreamehome.');
      }
      await _login();
      return;
    }
    if (_expiresAt == null ||
        DateTime.now().isAfter(_expiresAt!.subtract(const Duration(seconds: 100)))) {
      await _refresh();
    }
  }

  Future<List<DreameDevice>> getDevices() async {
    await _ensureSession();
    final data = await _postJson('/dreame-user-iot/iotuserbind/device/listV2', {
      'sharedStatus': 1,
      'current': 1,
      'size': 100,
      'lang': _language,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final payload = data['data'];
    dynamic records;
    if (payload is Map<String, dynamic>) {
      final page = payload['page'];
      records = page is Map<String, dynamic>
          ? page['records']
          : payload['records'];
    }
    records ??= data['records'];
    if (records is! List) return [];
    return records
        .whereType<Map>()
        .map((item) => DreameDevice.fromJson(Map<String, dynamic>.from(item)))
        .where((device) => device.id.isNotEmpty)
        .toList();
  }

  Future<List<DreameShortcut>> getShortcuts(String deviceId) async {
    final response = await _sendCommand(
      deviceId,
      method: 'get_properties',
      params: [
        {'did': deviceId, 'siid': 4, 'piid': 48},
      ],
    );
    final data = response['data'];
    final result = data is Map<String, dynamic> ? data['result'] : null;
    if (result is! List || result.isEmpty) return [];
    final rawValue = result.first is Map ? result.first['value'] : null;
    if (rawValue == null || rawValue.toString().isEmpty) return [];

    dynamic decoded = rawValue;
    if (rawValue is String) {
      try {
        decoded = jsonDecode(rawValue);
      } catch (_) {
        return [];
      }
    }
    if (decoded is! List) return [];

    final shortcuts = <DreameShortcut>[];
    for (final item in decoded.whereType<Map>()) {
      final id = int.tryParse(item['id']?.toString() ?? '');
      if (id == null) continue;
      var name = item['name']?.toString() ?? 'Сценарий $id';
      try {
        name = utf8.decode(base64.decode(base64.normalize(name)));
      } catch (_) {
        // Keep a readable plain-text name if the cloud already decoded it.
      }
      shortcuts.add(DreameShortcut(id: id, name: name));
    }
    return shortcuts;
  }

  Future<void> startShortcut(String deviceId, int shortcutId) async {
    if (shortcutId < 25 || shortcutId > 128) {
      throw DreameException('Недопустимый идентификатор сценария.');
    }
    await _startCustom(deviceId, 25, shortcutId.toString());
  }

  /// Starts cleaning one or more room segments by their map segment IDs.
  /// Segment IDs are read from the robot map; they are not room numbers.
  Future<void> cleanSegments(
    String deviceId,
    List<int> segmentIds, {
    int repeats = 1,
    int? suctionLevel,
    int? waterVolume,
  }) async {
    if (segmentIds.isEmpty) {
      throw DreameException('Не выбраны комнаты для уборки.');
    }
    final selects = segmentIds
        .map((id) => [id, max(1, repeats), suctionLevel ?? 1, waterVolume ?? 2, 1])
        .toList();
    await _startCustom(
      deviceId,
      18,
      jsonEncode({'selects': selects}),
    );
  }

  Future<void> _startCustom(String deviceId, int mode, String payload) async {
    await _sendCommand(
      deviceId,
      method: 'action',
      params: {
        'did': deviceId,
        'siid': 4,
        'aiid': 1,
        'in': [
          {'piid': 1, 'value': mode},
          {'piid': 10, 'value': payload},
        ],
      },
    );
  }

  Future<Map<String, dynamic>> _sendCommand(
    String deviceId, {
    required String method,
    required dynamic params,
  }) async {
    await _ensureSession();
    final id = Random.secure().nextInt(0x7ffffffe) + 1;
    return _postJson('/dreame-iot-com-10000/device/sendCommand', {
      'did': deviceId,
      'id': id,
      'data': {
        'did': deviceId,
        'id': id,
        'method': method,
        'params': params,
        'from': _commandFrom,
      },
    });
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    await _ensureSession();
    final response = await _client
        .post(
          Uri.parse('$_baseUrl$path'),
          headers: _headers(
            contentType: 'application/json',
            accessToken: _accessToken,
          ),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    return _decodeResponse(response);
  }

  Map<String, String> _headers({
    required String contentType,
    String? accessToken,
  }) {
    final plain = '$_region|$_language|$_country';
    final key = enc.Key.fromUtf8(_rlcKey);
    final cipher = enc.Encrypter(enc.AES(key, mode: enc.AESMode.ecb));
    final rlc = cipher.encrypt(plain).base16.toLowerCase();
    return {
      'user-agent': 'Dart/3.2 (dart:io)',
      'authorization': _oauthAuthorization,
      'content-type': contentType,
      'dreame-auth': accessToken == null ? 'bearer' : 'bearer $accessToken',
      'dreame-meta': _appMeta,
      'dreame-rlc': rlc,
      'tenant-id': _tenantId,
    };
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw DreameException(
        'Сервер Dreamehome вернул нечитаемый ответ (HTTP ${response.statusCode}).',
      );
    }
    if (decoded is! Map) {
      throw DreameException('Неожиданный формат ответа Dreamehome.');
    }
    final data = Map<String, dynamic>.from(decoded);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = data['error_description'] ?? data['msg'] ?? data['error'];
      throw DreameException(
        'Ошибка Dreamehome HTTP ${response.statusCode}'
        '${message == null ? '' : ': $message'}',
      );
    }
    final code = int.tryParse(data['code']?.toString() ?? '0') ?? 0;
    if (code != 0) {
      final message = data['msg']?.toString() ?? 'код $code';
      throw DreameException('Dreamehome отклонил команду: $message');
    }
    return data;
  }

  void dispose() => _client.close();
}

class DreameException implements Exception {
  final String message;
  const DreameException(this.message);

  @override
  String toString() => message;
}
