import 'package:flutter/material.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/services/dify_service.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math' as math;

class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  TestScreenState createState() => TestScreenState();
}

class TestScreenState extends State<TestScreen> {
  final _logs = <String>[];
  bool _isTesting = false;
  final ScrollController _scrollController = ScrollController();
  static const String _conversationMapKey = 'dify_conversation_map';

  void _addLog(String log) {
    setState(() {
      _logs.add('${DateTime.now().toString().substring(11, 19)}: $log');
      // 限制日志行数
      if (_logs.length > 100) {
        _logs.removeRange(0, _logs.length - 100);
      }
    });

    // 滚动到底部
    Future.delayed(const Duration(milliseconds: 10), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _testConsistentSession() async {
    final config = Provider.of<ConfigProvider>(context, listen: false);

    if (config.difyConfig == null) {
      _addLog('Ошибка: API Dify не настроен!');
      return;
    }

    setState(() {
      _isTesting = true;
      _logs.clear();
    });

    _addLog('Проверка сохранения сессии...');

    try {
      // 创建一个测试СессияID
      final sessionId = const Uuid().v4();
      _addLog('Используется ID сессии: $sessionId');

      final difyService = await DifyService.create(
        apiKey: config.difyConfig!.apiKey,
        apiUrl: config.difyConfig!.apiUrl,
      );

      // Отправка первого сообщения
      _addLog('Отправка первого сообщения');
      final response1 = await difyService.sendMessage(
        'Тестовое сообщение 1',
        sessionId: sessionId,
      );
      _addLog(
        'Получен ответ: ${response1.substring(0, math.min(20, response1.length))}...',
      );
      await _printCurrentSessions();

      // 等待一秒
      await Future.delayed(const Duration(seconds: 1));

      // Отправка второго сообщения
      _addLog('Отправка второго сообщения');
      final response2 = await difyService.sendMessage(
        'Тестовое сообщение 2',
        sessionId: sessionId,
      );
      _addLog(
        'Получен ответ: ${response2.substring(0, math.min(20, response2.length))}...',
      );
      await _printCurrentSessions();

      // 等待一秒
      await Future.delayed(const Duration(seconds: 1));

      // Отправка третьего сообщения
      _addLog('Отправка третьего сообщения');
      final response3 = await difyService.sendMessage(
        'Тестовое сообщение 3',
        sessionId: sessionId,
      );
      _addLog(
        'Получен ответ: ${response3.substring(0, math.min(20, response3.length))}...',
      );

      // 打印结果
      await _printCurrentSessions();

      _addLog('Проверка завершена');
    } catch (e) {
      _addLog('Ошибка проверки: $e');
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  Future<void> _testResetSession() async {
    final config = Provider.of<ConfigProvider>(context, listen: false);

    if (config.difyConfig == null) {
      _addLog('Ошибка: API Dify не настроен!');
      return;
    }

    setState(() {
      _isTesting = true;
      _logs.clear();
    });

    _addLog('Проверка сброса сессии...');

    try {
      // 创建一个测试СессияID
      final sessionId = const Uuid().v4();
      _addLog('Используется ID сессии: $sessionId');

      final difyService = await DifyService.create(
        apiKey: config.difyConfig!.apiKey,
        apiUrl: config.difyConfig!.apiUrl,
      );

      // 先发送一条消息
      _addLog('Отправка сообщения до сброса');
      final response1 = await difyService.sendMessage(
        'Сообщение до сброса',
        sessionId: sessionId,
      );
      _addLog(
        'Получен ответ: ${response1.substring(0, math.min(20, response1.length))}...',
      );

      // 打印当前СессияID
      await _printCurrentSessions();

      // Сброс сессии
      _addLog('Сброс сессии');
      await difyService.clearConversation(sessionId);

      // 打印重置后的СессияID
      await _printCurrentSessions();

      // 发送重置后的消息
      _addLog('Отправка сообщения после сброса');
      final response2 = await difyService.sendMessage(
        'Сообщение после сброса',
        sessionId: sessionId,
      );
      _addLog(
        'Получен ответ: ${response2.substring(0, math.min(20, response2.length))}...',
      );

      // 打印最终СессияID
      await _printCurrentSessions();

      _addLog('Проверка завершена');
    } catch (e) {
      _addLog('Ошибка проверки: $e');
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  Future<void> _printStoredSessions() async {
    setState(() {
      _isTesting = true;
      _logs.clear();
    });

    _addLog('Получение сохранённых ID сессий...');

    try {
      await _printCurrentSessions();
      _addLog('Готово');
    } catch (e) {
      _addLog('Ошибка: $e');
    } finally {
      setState(() {
        _isTesting = false;
      });
    }
  }

  Future<void> _printCurrentSessions() async {
    final prefs = await SharedPreferences.getInstance();
    final mapJson = prefs.getString(_conversationMapKey);
    if (mapJson == null || mapJson.isEmpty) {
      _addLog('Нет сохранённых ID сессий');
      return;
    }

    final Map<String, dynamic> loadedMap = jsonDecode(mapJson);
    _addLog('Сохранённые ID сессий:');
    loadedMap.forEach((sessionId, conversationId) {
      _addLog('- Сессия: $sessionId => ID диалога: $conversationId');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Проверка ID сессий Dify'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed:
                _logs.isEmpty ? null : () => setState(() => _logs.clear()),
            tooltip: 'Очистить журнал',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isTesting ? null : _testConsistentSession,
                    child: const Text('Проверить сохранение сессии'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isTesting ? null : _testResetSession,
                    child: const Text('Проверить сброс сессии'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isTesting ? null : _printStoredSessions,
                    child: const Text('Показать сохранённые сессии'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(child: _buildLogView()),
        ],
      ),
    );
  }

  Widget _buildLogView() {
    if (_logs.isEmpty) {
      return const Center(child: Text('Журнал пуст. Запустите проверку.'));
    }

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: ListView.builder(
            controller: _scrollController,
            itemCount: _logs.length,
            itemBuilder: (context, index) {
              return Text(
                _logs[index],
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: _getLogColor(_logs[index]),
                ),
              );
            },
          ),
        ),
        if (_isTesting)
          const Positioned.fill(
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Color _getLogColor(String log) {
    if (log.contains('Ошибка') || log.contains('Ошибка')) {
      return Colors.red;
    } else if (log.contains('Готово') || log.contains('Успешно')) {
      return Colors.green;
    } else if (log.contains('Сессия') || log.contains('ID диалога')) {
      return Colors.blue;
    } else {
      return Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black;
    }
  }
}
