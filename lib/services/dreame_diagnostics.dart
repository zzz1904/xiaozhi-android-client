import 'package:shared_preferences/shared_preferences.dart';

/// Persistent, privacy-safe diagnostics shared by the Dreame settings screen
/// and voice command handler.
class DreameDiagnostics {
  DreameDiagnostics._();

  static const _storageKey = 'dreame.diagnosticEvents';
  static const _limit = 120;

  static Future<void> record(String event) async {
    final line = '${DateTime.now().toIso8601String()} | $event';
    try {
      final prefs = await SharedPreferences.getInstance();
      final events = prefs.getStringList(_storageKey) ?? <String>[];
      events.add(line);
      if (events.length > _limit) {
        events.removeRange(0, events.length - _limit);
      }
      await prefs.setStringList(_storageKey, events);
    } catch (_) {
      // Diagnostics must never interrupt robot control.
    }
  }

  static Future<String> buildReport({Object? error, StackTrace? stackTrace}) async {
    List<String> events = <String>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      events = prefs.getStringList(_storageKey) ?? <String>[];
    } catch (_) {
      // Return the report header even if local storage is unavailable.
    }
    return <String>[
      'Диагностика Dreamehome',
      'Время: ${DateTime.now().toIso8601String()}',
      if (error != null) 'Ошибка: $error',
      'Последние события:',
      if (events.isEmpty) 'Событий пока нет.' else ...events,
      if (stackTrace != null) 'Стек ошибки:\n$stackTrace',
      'Пароли и токены в журнал не записываются.',
    ].join('\n');
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_storageKey);
    } catch (_) {
      // Ignore diagnostic cleanup errors.
    }
  }
}
