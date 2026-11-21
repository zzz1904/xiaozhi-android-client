import 'package:ai_assistant/services/dreame_service.dart';
import 'package:ai_assistant/services/dreame_diagnostics.dart';

/// Detects supported Dreame commands in XiaoZhi speech-recognition events.
class DreameVoiceCommandHandler {
  final DreameService _service = DreameService();
  bool _busy = false;

  bool isCommand(String recognizedText) =>
      _looksLikeVacuumCommand(_normalize(recognizedText));

  Future<String?> handle(String recognizedText) async {
    final text = _normalize(recognizedText);
    await DreameDiagnostics.record('Dreame handler: вызван; исходный текст="$recognizedText"; normalized="$text"; busy=$_busy.');
    if (_busy) {
      await DreameDiagnostics.record('Dreame handler: отказ — обработчик уже занят.');
      return null;
    }
    if (!isCommand(recognizedText)) {
      await DreameDiagnostics.record('Dreame handler: текст не прошёл повторную проверку isCommand.');
      return null;
    }

    await DreameDiagnostics.record('Голосовая команда Dreame: распознана команда уборки (длина текста: ${text.length}).');
    _busy = true;
    try {
      final saved = await _service.loadSavedSettings();
      if ((saved['email'] ?? '').isEmpty ||
          (saved['password'] ?? '').isEmpty) {
        return 'Сначала подключите аккаунт Dreamehome в настройках приложения.';
      }

      await _service.restoreSession();
      final devices = await _service.getDevices();
      await DreameDiagnostics.record('Голосовая команда: доступных устройств: ${devices.length}.');
      if (devices.isEmpty) return 'В аккаунте Dreamehome не найден пылесос.';

      final preferredId = await _service.loadSelectedDeviceId();
      final matchingDevices =
          devices.where((device) => device.id == preferredId);
      final device =
          matchingDevices.isEmpty ? devices.first : matchingDevices.first;

      // Saved Dreamehome routines take priority over map rooms. This allows
      // natural phrases such as "сделай уборку в прихожей" to launch a
      // routine named "Прихожая", without requiring the word "сценарий".
      try {
        final shortcuts = await _service.getShortcuts(device.id);
        for (final shortcut in shortcuts) {
          if (_matchesNamedTarget(text, shortcut.name)) {
            await DreameDiagnostics.record(
              'Голосовая команда: найдено совпадение с сохранённой командой «${shortcut.name}».',
            );
            await _service.startShortcut(device.id, shortcut.id);
            return 'Запрос на запуск команды «${shortcut.name}» передан Dreamehome. Фактический старт робота пока не подтверждён.';
          }
        }
        await DreameDiagnostics.record(
          'Голосовая команда: совпадение с сохранёнными командами не найдено; проверяю комнаты карты.',
        );
      } catch (error) {
        // A shortcut lookup failure must not prevent ordinary room cleaning.
        await DreameDiagnostics.record(
          'Голосовая команда: не удалось проверить сохранённые команды (${error.runtimeType}); перехожу к комнатам карты.',
        );
      }

      final rooms = await _service.getRooms(device);
      await DreameDiagnostics.record('Голосовая команда: с карты получено комнат: ${rooms.length}; названия=[${rooms.map((room) => room.name).join(" | ")}].');
      if (rooms.isEmpty) return 'На карте пылесоса не удалось найти комнаты.';

      final wholeHome = _isWholeHomeRequest(text);
      final selectedRooms = wholeHome
          ? rooms
          : rooms.where((room) => _matchesRoom(text, room.name)).toList();
      await DreameDiagnostics.record('Голосовая команда: wholeHome=$wholeHome; выбраны комнаты=[${selectedRooms.map((room) => "${room.name}(id=${room.id})").join(", ")}].');
      if (selectedRooms.isEmpty) {
        return 'Не нашёл такую комнату или команду в Dreamehome. Проверьте название комнаты на карте и сохранённые быстрые команды.';
      }

      // Apply the requested default route before setting the cleaning mode.
      // The route is stored separately from CLEANING_MODE and must not be
      // included in the START_CUSTOM room payload.
      await _service.setCleaningRoute(device.id, 4);
      await DreameDiagnostics.record('Голосовая команда: выбран быстрый маршрут уборки.');

      final mode = _requestedCleaningMode(text);
      await DreameDiagnostics.record('Голосовая команда: выбран режим уборки=${mode ?? "не меняю текущий"}.');
      if (mode != null) {
        await _service.setCleaningMode(device.id, mode);
        await DreameDiagnostics.record('Голосовая команда: режим $mode подтверждён роботом.');
      }
      await DreameDiagnostics.record('Голосовая команда: запускаю уборку комнат, сегментов: ${selectedRooms.length}.');
      await _service.cleanSegments(
        device.id,
        selectedRooms.map((room) => room.id).toList(),
      );
      await DreameDiagnostics.record('Голосовая команда: запрос уборки отправлен.');

      final roomDescription = wholeHome
          ? 'всей квартиры'
          : selectedRooms.map((room) => room.name).join(', ');
      return 'Запрос на уборку $roomDescription передан Dreamehome. Фактический старт робота пока не подтверждён.';
    } catch (error) {
      await DreameDiagnostics.record('Голосовая команда: ошибка выполнения: $error');
      return 'Не удалось выполнить команду Dreame: $error';
    } finally {
      _busy = false;
    }
  }

  bool _looksLikeVacuumCommand(String text) {
    return text.contains('убери') ||
        text.contains('пропылесось') ||
        text.contains('пылесось') ||
        text.contains('помой') ||
        text.contains('помыть') ||
        text.contains('влажная уборка') ||
        text.contains('сухая уборка') ||
        text.contains('сценарий') ||
        text.contains('сделай уборку') ||
        text.contains('сделать уборку') ||
        text.startsWith('сделать ') ||
        text == 'сделать' ||
        text.startsWith('сделаю ') ||
        text == 'сделаю' ||
        text.startsWith('делать ') ||
        text == 'делать' ||
        text.startsWith('пылесосить ') ||
        text == 'пылесосить' ||
        text.contains('запусти команду') ||
        text.contains('запусти уборку') ||
        text.contains('начни уборку') ||
        text.startsWith('запусти ') ||
        text.startsWith('включи ') ||
        text.startsWith('активируй ');
  }

  bool _isWholeHomeRequest(String text) {
    return text.contains('всю квартиру') ||
        text.contains('вся квартира') ||
        text.contains('везде') ||
        text.contains('весь дом') ||
        text.contains('все комнаты') ||
        text.contains('по всей квартире');
  }

  /// Matches all meaningful words of a saved command name against the
  /// recognized phrase, allowing common Russian grammatical endings.
  bool _matchesNamedTarget(String text, String targetName) {
    final targetWords = _normalize(targetName)
        .split(' ')
        .where((word) => word.length >= 3)
        .map(_stemRussianWord)
        .toList();
    if (targetWords.isEmpty) return false;

    final spokenWords = _normalize(text)
        .split(' ')
        .where((word) => word.length >= 3)
        .map(_stemRussianWord)
        .toSet();
    return targetWords.every(spokenWords.contains);
  }

  String _stemRussianWord(String word) {
    // Normalize common adjective, noun and case endings:
    // прихожая / прихожей / прихожую -> прихож.
    const endings = [
      'иями', 'ями', 'ами', 'ого', 'его', 'ому', 'ему',
      'ыми', 'ими', 'ая', 'яя', 'ую', 'юю', 'ое', 'ее',
      'ые', 'ие', 'ей', 'ой', 'ый', 'ий', 'ом', 'ем',
      'ам', 'ям', 'ах', 'ях', 'ов', 'ев', 'а', 'я',
      'ы', 'и', 'у', 'ю', 'е', 'о',
    ];
    for (final ending in endings) {
      if (word.endsWith(ending) && word.length - ending.length >= 3) {
        return word.substring(0, word.length - ending.length);
      }
    }
    return word;
  }

  bool _matchesRoom(String text, String roomName) {
    final name = _normalize(roomName);
    if (name.isEmpty) return false;
    if (text.contains(name)) return true;

    // Match common Russian case endings: «кухня» / «кухню», «спальня» / «спальню».
    final stem = _stemRussianWord(name);
    if (stem.length >= 3 && text.split(' ').any(
      (word) => _stemRussianWord(word) == stem,
    )) return true;

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
      final russianStem = _stemRussianWord(entry.key);
      final mapNameMatches = name == entry.key ||
          name == russianStem ||
          entry.value.any((alias) => name.contains(alias));
      final spokenNameMatches = text.contains(entry.key) ||
          text.split(' ').any((word) => _stemRussianWord(word) == russianStem) ||
          entry.value.any((alias) => text.contains(alias));
      if (mapNameMatches && spokenNameMatches) return true;
    }
    return false;
  }

  int? _requestedCleaningMode(String text) {
    if (text.contains('и помой') || text.contains('пылесос и влажная')) {
      return 2; // Vacuum and mop.
    }
    if (text.contains('пропылесось') ||
        text.contains('пылесось') ||
        text.startsWith('пылесосить ') ||
        text == 'пылесосить' ||
        text.contains('только пылесос') ||
        text.contains('сухая уборка')) {
      return 0; // Vacuum.
    }
    if (text.contains('помой') ||
        text.contains('помыть') ||
        text.contains('влажная уборка')) {
      return 1; // Mop.
    }
    if (text.contains('сделай уборку') ||
        text.contains('сделать уборку') ||
        text.startsWith('сделать ') ||
        text == 'сделать' ||
        text.startsWith('сделаю ') ||
        text == 'сделаю' ||
        text.startsWith('делать ') ||
        text == 'делать') {
      return 2; // Generic cleaning requests mean vacuum + mop.
    }
    return null; // Keep the robot's current mode for other generic commands.
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r'[^a-zа-я0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  void dispose() => _service.dispose();
}
