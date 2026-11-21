import 'package:ai_assistant/services/dreame_service.dart';

/// Detects supported Dreame commands in XiaoZhi's speech-recognition events.
/// Ordinary conversation is left untouched and never opens a Dreame session.
class DreameVoiceCommandHandler {
  final DreameService _service = DreameService();
  bool _busy = false;

  Future<String?> handle(String recognizedText) async {
    final text = _normalize(recognizedText);
    if (_busy || !_looksLikeVacuumCommand(text)) return null;
    _busy = true;
    try {
      final saved = await _service.loadSavedSettings();
      if ((saved['email'] ?? '').isEmpty || (saved['password'] ?? '').isEmpty) {
        return null;
      }

      await _service.restoreSession();
      final devices = await _service.getDevices();
      if (devices.isEmpty) return 'В аккаунте Dreamehome не найден пылесос.';
      final preferredId = await _service.loadSelectedDeviceId();
      final matches = devices.where((device) => device.id == preferredId);
      final device = matches.isEmpty ? devices.first : matches.first;

      if (_isShortcutRequest(text)) {
        final shortcuts = await _service.getShortcuts(device.id);
        final shortcutMatches = shortcuts.where((shortcut) {
          final name = _normalize(shortcut.name);
          return name.length >= 3 && text.contains(name);
        });
        if (shortcutMatches.isNotEmpty) {
          final shortcut = shortcutMatches.first;
          await _service.startShortcut(device.id, shortcut.id);
          return 'Запустил сценарий «${shortcut.name}».';
        }
      }

      final rooms = await _service.getRooms(device);
      if (rooms.isEmpty) return 'На карте пылесоса не удалось найти комнаты.';
      final allRooms = _isWholeHomeRequest(text);
      final selected = allRooms
          ? rooms
          : rooms.where((room) => _matchesRoom(text, room.name)).toList();
      if (selected.isEmpty) return null;

      final mode = _requestedCleaningMode(text);
      if (mode != null) {
        await _service.setCleaningMode(device.id, mode);
      }
      await _service.cleanSegments(
        device.id,
        selected.map((room) => room.id).toList(),
      );
      final names = allRooms
          ? 'всей квартиры'
          : selected.map((room) => room.name).join(', ');
      return 'Отправил роботу команду на уборку: $names.';
    } catch (error) {
      return 'Не удалось выполнить команду Dreame: $error';
    } finally {
      _busy = false;
    }
  }

  bool _looksLikeVacuumCommand(String text) {
    return text.contains('убери') ||
        text.contains('уборку') ||
        text.contains('пропылесось') ||
        text.contains('пылесос') ||
        text.contains('помой') ||
        text.contains('помыть') ||
        text.contains('влажная уборка') ||
        text.contains('сухая уборка') ||
        text.contains('запусти сценарий') ||
        text.contains('запусти команду');
  }

  bool _isShortcutRequest(String text) {
    return text.contains('сценарий') ||
        text.contains('быструю команду') ||
        text.contains('запусти команду') ||
        text.contains('запусти уборку');
  }

  bool _isWholeHomeRequest(String text) {
    return text.contains('всю квартиру') ||
        text.contains('вся квартира') ||
        text.contains('везде') ||
        text.contains('весь дом') ||
        text.contains('все комнаты') ||
        text.contains('по всей квартире');
  }

  bool _matchesRoom(String text, String roomName) {
    final name = _normalize(roomName);
    if (name.isEmpty) return false;
    if (text.contains(name)) return true;

    // Russian room names are commonly spoken in the accusative case:
    // "кухня" -> "кухню", "спальня" -> "спальню", "ванная" -> "ванную".
    final stem = name.replaceFirst(RegExp(r'(ая|яя|ия|а|я|ы|и|ь|й)$'), '');
    if (stem.length >= 3 && text.contains(stem)) return true;

    const aliases = <String, List<String>>{
      'кухня': ['kitchen'],
      'коридор': ['hall', 'hallway', 'corridor'],
      'гостиная': ['living room', 'livingroom'],
      'спальня': ['bedroom'],
      'детская': ['kids room', 'children room'],
      'ванная': ['bathroom'],
      'туалет': ['toilet', 'wc'],
      'кабинет': ['office', 'study'],
    };
    for (final entry in aliases.entries) {
      if (name == entry.key || stem == entry.key.replaceFirst(RegExp(r'(ая|яя|ия|а|я|ы|и|ь|й)$'), '')) {
        if (entry.value.any(text.contains)) return true;
      }
    }
    return false;
  }

  int? _requestedCleaningMode(String text) {
    if (text.contains('и помой') || text.contains('пылесос и влажная')) {
      return 2; // vacuum and mop
    }
    if (text.contains('пропылесось') ||
        text.contains('только пылесос') ||
        text.contains('сухая уборка')) {
      return 0; // sweeping / vacuuming
    }
    if (text.contains('помой') ||
        text.contains('помыть') ||
        text.contains('влажная уборка')) {
      return 1; // mopping
    }
    return null; // "убери" keeps the robot's current cleaning mode.
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r'[^\\p{L}\\p{N}\\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void dispose() => _service.dispose();
}
