import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'dreame_diagnostics.dart';

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
    final id = (json['did'] ?? json['deviceId'] ?? json['device_id'] ?? json['id'] ?? '').toString();
    final model = (json['model'] ?? json['modelName'] ?? json['productName'] ?? '').toString();
    final name = (json['customName'] ?? json['deviceName'] ?? json['name'] ?? model).toString();
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

/// A room (map segment) on the robot's active saved map.
class DreameRoom {
  final int id;
  final String name;
  final int mapId;
  final String mapName;

  const DreameRoom({
    required this.id,
    required this.name,
    required this.mapId,
    required this.mapName,
  });
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

    await DreameDiagnostics.record('Подключение: запуск авторизации для региона $_region, страна $_country.');
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
    await DreameDiagnostics.record('Сессия восстановлена: логин сохранён=${_email?.isNotEmpty == true}, access token сохранён=${_accessToken?.isNotEmpty == true}, refresh token сохранён=${_refreshToken?.isNotEmpty == true}, срок действия=${_expiresAt?.toIso8601String() ?? "неизвестен"}.');
  }

  Future<void> saveSelectedDeviceId(String deviceId) async {
    await _storage.write(key: 'dreame.deviceId', value: deviceId);
  }

  Future<String?> loadSelectedDeviceId() {
    return _storage.read(key: 'dreame.deviceId');
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
      'dreame.deviceId',
    ]) {
      await _storage.delete(key: key);
    }
  }

  Future<void> _login() async {
    await DreameDiagnostics.record('Авторизация: отправка password grant на $_host.');
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
    try {
      await _requestToken({
        'grant_type': 'refresh_token',
        'refresh_token': token,
      });
    } catch (_) {
      // The refresh token can be revoked independently of the password.
      // Retry with the saved account credentials before reporting a failure.
      if (_email == null || _email!.isEmpty || _password == null || _password!.isEmpty) {
        rethrow;
      }
      await _login();
    }
  }

  Future<void> _requestToken(Map<String, String> form) async {
    final response = await _client
        .post(
          Uri.parse('$_baseUrl/dreame-auth/oauth/token'),
          headers: _headers(contentType: 'application/x-www-form-urlencoded'),
          body: form,
        )
        .timeout(const Duration(seconds: 25));
    await DreameDiagnostics.record('Авторизация: HTTP ${response.statusCode}, получен ответ сервера.');
    final data = await _decodeResponse(response);
    await DreameDiagnostics.record('Авторизация: поля ответа ${data.keys.toList()}, access token присутствует=${(data['access_token']?.toString().isNotEmpty ?? false)}.');
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
      await DreameDiagnostics.record('Сессия: access token отсутствует, выполняется повторный вход по сохранённым данным.');
      await _login();
      return;
    }
    if (_expiresAt == null ||
        DateTime.now().isAfter(_expiresAt!.subtract(const Duration(seconds: 100)))) {
      await DreameDiagnostics.record('Сессия: access token истёк или срок неизвестен, обновляю токен.');
      await _refresh();
    }
  }

  Future<List<DreameDevice>> getDevices() async {
    await DreameDiagnostics.record('Устройства: начинаю запрос списка устройств (listV2).');
    await _ensureSession();
    await DreameDiagnostics.record(
      'Устройства: параметры запроса region=$_region, country=$_country, lang=$_language, uid сохранён=${_uid?.isNotEmpty == true}.',
    );
    final data = await _postJson('/dreame-user-iot/iotuserbind/device/listV2', {
      'sharedStatus': 1,
      'current': 1,
      'size': 100,
      'lang': _language,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final payload = _decodeNestedJson(data['data']);
    await DreameDiagnostics.record(
      'Устройства: HTTP-ответ успешно разобран; структура data=${_describeShape(payload)}.',
    );
    final records = _extractDeviceRecords(payload) ??
        _extractDeviceRecords(data['records']) ??
        _extractDeviceRecords(data['result']);
    if (records == null) {
      await DreameDiagnostics.record(
        'Устройства: список не найден. Структура ответа: ${_describeShape(data)}.',
      );
      return [];
    }
    final devices = records
        .whereType<Map>()
        .map((item) => DreameDevice.fromJson(Map<String, dynamic>.from(item)))
        .where((device) => device.id.isNotEmpty)
        .toList();
    await DreameDiagnostics.record(
      'Устройства: найдено записей=${records.length}, распознано устройств=${devices.length}.',
    );
    if (devices.isEmpty && records.isNotEmpty) {
      await DreameDiagnostics.record(
        'Устройства: поля первой записи=${records.first is Map ? (records.first as Map).keys.toList() : records.first.runtimeType}.',
      );
    }
    return devices;
  }

  dynamic _decodeNestedJson(dynamic value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  List<dynamic>? _extractDeviceRecords(dynamic value, [int depth = 0]) {
    if (depth > 6 || value == null) return null;
    final decoded = _decodeNestedJson(value);
    if (decoded is List) {
      if (decoded.isEmpty) return decoded;
      if (decoded.any((item) => item is Map &&
          (item.containsKey('did') || item.containsKey('deviceId') ||
           item.containsKey('device_id') || item.containsKey('id')))) {
        return decoded;
      }
      for (final item in decoded) {
        final nested = _extractDeviceRecords(item, depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
      return null;
    }
    if (decoded is Map) {
      if (decoded.containsKey('did') || decoded.containsKey('deviceId') ||
          decoded.containsKey('device_id')) {
        return [decoded];
      }
      List<dynamic>? emptyCandidate;
      for (final key in const [
        'page', 'records', 'list', 'devices', 'deviceList',
        'device_list', 'data', 'result', 'rows',
      ]) {
        if (decoded.containsKey(key)) {
          final nested = _extractDeviceRecords(decoded[key], depth + 1);
          if (nested != null) {
            if (nested.isNotEmpty) return nested;
            emptyCandidate ??= nested;
          }
        }
      }
      return emptyCandidate;
    }
    return null;
  }

  String _describeShape(dynamic value, [int depth = 0]) {
    if (depth > 4) return '…';
    final decoded = _decodeNestedJson(value);
    if (decoded is Map) {
      final entries = decoded.entries.take(20).map((entry) =>
          '${entry.key}:${_describeShape(entry.value, depth + 1)}');
      return '{${entries.join(', ')}'
          '${decoded.length > 20 ? ', …' : ''}}';
    }
    if (decoded is List) {
      return 'List(length=${decoded.length}'
          '${decoded.isEmpty ? '' : ', first=${_describeShape(decoded.first, depth + 1)}'})';
    }
    if (decoded == null) return 'null';
    return decoded.runtimeType.toString();
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
        final encodedName = name.replaceAll('+', '-').replaceAll('/', '_');
            name = utf8.decode(base64Url.decode(base64Url.normalize(encodedName)));
      } catch (_) {
        // Keep a readable plain-text name if the cloud already decoded it.
      }
      shortcuts.add(DreameShortcut(id: id, name: name));
    }
    return shortcuts;
  }

  /// Reads the active saved map and extracts room/segment identifiers.
  /// Room IDs are taken from the map pixel grid; names come from seg_inf.
  Future<List<DreameRoom>> getRooms(DreameDevice device) async {
    final pointerResponse = await _sendCommand(
      device.id,
      method: 'get_properties',
      params: [
        {'did': device.id, 'siid': 6, 'piid': 8},
      ],
    );
    final responseData = pointerResponse['data'];
    final result = responseData is Map<String, dynamic>
        ? responseData['result']
        : null;
    if (result is! List || result.isEmpty || result.first is! Map) {
      throw DreameException('Робот пока не предоставил список сохранённых карт.');
    }

    dynamic pointerValue = result.first['value'];
    if (pointerValue is String) {
      try {
        pointerValue = jsonDecode(pointerValue);
      } catch (_) {
        throw DreameException('Не удалось прочитать указатель карты робота.');
      }
    }
    if (pointerValue is! Map) {
      throw DreameException('Сохранённая карта ещё не доступна в облаке.');
    }
    final filename = (pointerValue['object_name'] ?? pointerValue['obj_name'])?.toString();
    if (filename == null || filename.isEmpty) {
      throw DreameException('В ответе Dreamehome отсутствует адрес файла карты.');
    }

    final urlResponse = await _postJson('/dreame-user-iot/iotfile/getDownloadUrl', {
      'did': device.id,
      'model': device.model,
      'filename': filename,
      'region': _region,
    });
    final signedUrl = urlResponse['data']?.toString();
    if (signedUrl == null || !signedUrl.startsWith('http')) {
      throw DreameException('Dreamehome не вернул ссылку для загрузки карты.');
    }

    final mapResponse = await _client
        .get(Uri.parse(signedUrl))
        .timeout(const Duration(seconds: 30));
    if (mapResponse.statusCode < 200 || mapResponse.statusCode >= 300) {
      throw DreameException('Не удалось загрузить карту робота (HTTP ${mapResponse.statusCode}).');
    }

    dynamic wrapper;
    try {
      wrapper = jsonDecode(utf8.decode(mapResponse.bodyBytes));
    } catch (_) {
      throw DreameException('Файл карты имеет неизвестный формат.');
    }
    if (wrapper is! Map || wrapper['mapstr'] is! List) {
      throw DreameException('В файле карты не найден список этажей.');
    }

    final mapEntries = (wrapper['mapstr'] as List).whereType<Map>().toList();
    if (mapEntries.isEmpty) {
      throw DreameException('Сохранённая карта не содержит данных помещений.');
    }
    final currentMapId = int.tryParse(wrapper['curr_id']?.toString() ?? '');
    final decodedMaps = <_DecodedDreameMap>[];
    for (final entry in mapEntries) {
      final encoded = entry['map']?.toString();
      if (encoded == null || encoded.isEmpty) continue;
      try {
        decodedMaps.add(
          _decodeSavedMap(
            encoded,
            mapName: entry['name']?.toString() ?? 'Этаж',
          ),
        );
      } catch (_) {
        // A damaged or unsupported floor must not hide other saved floors.
      }
    }
    if (decodedMaps.isEmpty) {
      throw DreameException('Не удалось декодировать сохранённую карту.');
    }
    final active = decodedMaps.where((map) => map.mapId == currentMapId);
    final selectedMap = active.isEmpty ? decodedMaps.first : active.first;
    if (selectedMap.rooms.isEmpty) {
      throw DreameException('На активной карте не обнаружены комнаты.');
    }
    return selectedMap.rooms;
  }

  _DecodedDreameMap _decodeSavedMap(
    String encoded, {
    required String mapName,
  }) {
    final comma = encoded.indexOf(',');
    if (comma >= 0) {
      throw const DreameException(
        'Карта использует дополнительное шифрование, которое пока не поддерживается.',
      );
    }
    final normalized = encoded
        .replaceAll('+', '-')
        .replaceAll('/', '_');
    final compressed = base64Url.decode(base64Url.normalize(normalized));
    final inflated = Uint8List.fromList(ZLibDecoder().convert(compressed));
    if (inflated.length < 27) {
      throw const DreameException('Повреждён заголовок карты.');
    }
    final header = ByteData.sublistView(inflated);
    final mapId = header.getInt16(0, Endian.little);
    final width = header.getInt16(19, Endian.little);
    final height = header.getInt16(21, Endian.little);
    if (width <= 0 || height <= 0 || 27 + width * height > inflated.length) {
      throw const DreameException('Некорректные размеры карты.');
    }

    final tailOffset = 27 + width * height;
    final tailText = utf8.decode(inflated.sublist(tailOffset), allowMalformed: true);
    final tail = jsonDecode(tailText);
    final segmentInfo = tail is Map ? tail['seg_inf'] : null;
    final roomIds = <int>{};
    if (segmentInfo is Map) {
      for (final key in segmentInfo.keys) {
        final id = int.tryParse(key.toString());
        if (id != null && id > 0 && id < 61) roomIds.add(id);
      }
    }
    // Fallback for maps that do not publish seg_inf: fsm:1 stores the
    // segment ID in the upper six bits; older frames use the low six bits.
    if (roomIds.isEmpty) {
      final frameMap = tail is Map && tail['fsm'] == 1;
      for (var i = 27; i < 27 + width * height; i++) {
        final pixel = inflated[i];
        final id = frameMap ? pixel >> 2 : pixel & 0x3f;
        if (id > 0 && id < 61) roomIds.add(id);
      }
    }
    final rooms = roomIds.toList()..sort();
    return _DecodedDreameMap(
      mapId: mapId,
      rooms: rooms.map((id) {
        final info = segmentInfo is Map ? segmentInfo[id.toString()] : null;
        var name = info is Map ? info['name']?.toString() ?? '' : '';
        if (name.isNotEmpty) {
          try {
            final encodedName = name.replaceAll('+', '-').replaceAll('/', '_');
            name = utf8.decode(base64Url.decode(base64Url.normalize(encodedName)));
          } catch (_) {
            // Keep the raw map name if it isn't base64 encoded.
          }
        }
        if (name.trim().isEmpty) name = 'Комната $id';
        return DreameRoom(
          id: id,
          name: name,
          mapId: mapId,
          mapName: mapName,
        );
      }).toList(),
    );
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
    var fan = suctionLevel ?? 1;
    var water = waterVolume ?? 2;
    if (suctionLevel == null || waterVolume == null) {
      try {
        final current = await _sendCommand(
          deviceId,
          method: 'get_properties',
          params: [
            {'did': deviceId, 'siid': 4, 'piid': 4},
            {'did': deviceId, 'siid': 4, 'piid': 5},
          ],
        );
        final currentData = current['data'];
        final values = currentData is Map<String, dynamic> ? currentData['result'] : null;
        if (values is List) {
          for (final item in values.whereType<Map>()) {
            final siid = int.tryParse(item['siid']?.toString() ?? '');
            final piid = int.tryParse(item['piid']?.toString() ?? '');
            final value = int.tryParse(item['value']?.toString() ?? '');
            if (value == null) continue;
            if (siid == 4 && piid == 4 && suctionLevel == null) fan = value;
            if (siid == 4 && piid == 5 && waterVolume == null) water = value;
          }
        }
      } catch (_) {
        // Use safe defaults when a device does not answer the optional read.
      }
    }
    final selects = segmentIds
        .map((id) => [id, max(1, repeats), fan, water, 1])
        .toList();
    await _startCustom(
      deviceId,
      18,
      jsonEncode({'selects': selects}),
    );
  }

  Future<void> setCleaningMode(String deviceId, int mode) async {
    if (mode < 0 || mode > 3) {
      throw DreameException('Недопустимый режим уборки.');
    }
    await _sendCommand(
      deviceId,
      method: 'set_properties',
      params: [
        {'did': deviceId, 'siid': 2, 'piid': 6, 'value': mode},
      ],
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
    // Dreame cloud command IDs are expected to be in the 1000–9999 range.
    final id = 1000 + Random.secure().nextInt(9000);
    final stopwatch = Stopwatch()..start();
    final paramsShape = params is List
        ? 'list(length=${params.length})'
        : params is Map
            ? 'map(keys=${params.keys.toList()})'
            : params.runtimeType.toString();
    final propertyRefs = params is List
        ? params.whereType<Map>().map((item) =>
            '${item['siid'] ?? '?'}/${item['piid'] ?? item['aiid'] ?? '?'}').join(',')
        : params is Map
            ? '${params['siid'] ?? '?'}/${params['piid'] ?? params['aiid'] ?? '?'}'
            : 'n/a';
    await DreameDiagnostics.record(
      'Команда Dreame: method=$method, params=$paramsShape, refs=$propertyRefs.',
    );
    try {
      final response = await _postJson('/dreame-iot-com-10000/device/sendCommand', {
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
      stopwatch.stop();
      final data = response['data'];
      final result = data is Map ? data['result'] : null;
      await DreameDiagnostics.record(
        'Команда Dreame $method: ответ за ${stopwatch.elapsedMilliseconds} мс; '
        'result=${result is List ? 'list(${result.length})' : result.runtimeType}.',
      );
      return response;
    } catch (error) {
      stopwatch.stop();
      await DreameDiagnostics.record(
        'Команда Dreame $method: ошибка через ${stopwatch.elapsedMilliseconds} мс '
        '(${error.runtimeType}).',
      );
      rethrow;
    }
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
    await DreameDiagnostics.record('HTTP POST $path: отправлен запрос.');
    await DreameDiagnostics.record('HTTP POST $path: получен статус ${response.statusCode}.');
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

  Future<Map<String, dynamic>> _decodeResponse(http.Response response) async {
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
    await DreameDiagnostics.record('HTTP ${response.statusCode}: code=$code, поля ответа=${data.keys.toList()}.');
    if (code == 80001) {
      throw const DreameCommandUnconfirmedException(
        'Облачный запрос завершился тайм-аутом (80001). Если это была команда управления, она могла быть принята роботом.',
      );
    }
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


/// The cloud did not receive a device acknowledgement in time.
/// The command may nevertheless have reached the vacuum.
class DreameCommandUnconfirmedException extends DreameException {
  const DreameCommandUnconfirmedException(super.message);
}


class _DecodedDreameMap {
  final int mapId;
  final List<DreameRoom> rooms;

  const _DecodedDreameMap({required this.mapId, required this.rooms});
}
