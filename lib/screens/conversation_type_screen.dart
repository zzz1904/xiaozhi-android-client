import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/screens/chat_screen.dart';
import 'package:ai_assistant/screens/settings_screen.dart';

class ConversationTypeScreen extends StatefulWidget {
  const ConversationTypeScreen({super.key});
  @override
  State<ConversationTypeScreen> createState() => _ConversationTypeScreenState();
}

class _ConversationTypeScreenState extends State<ConversationTypeScreen> {
  XiaozhiConfig? _selectedConfig;
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Новый диалог')),
      body: Consumer<ConfigProvider>(
        builder: (context, provider, _) {
          final configs = provider.xiaozhiConfigs;
          if (_selectedConfig == null && configs.isNotEmpty) _selectedConfig = configs.first;
          if (configs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.mic_none, size: 56, color: colors.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text('Сервис XiaoZhi ещё не настроен',
                    style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text('Сначала подключите устройство к консоли XiaoZhi или добавьте сервис в настройках.',
                    textAlign: TextAlign.center, style: TextStyle(color: colors.onSurfaceVariant)),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen())),
                    child: const Text('Открыть настройки')),
                ]),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Выберите сервис XiaoZhi', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Новый диалог будет создан через выбранное подключение.',
                style: TextStyle(color: colors.onSurfaceVariant)),
              const SizedBox(height: 20),
              DropdownButtonFormField<XiaozhiConfig>(
                value: configs.contains(_selectedConfig) ? _selectedConfig : configs.first,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Подключение'),
                items: configs.map((config) => DropdownMenuItem(
                  value: config, child: Text(config.name, overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (value) => setState(() => _selectedConfig = value),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _creating || _selectedConfig == null ? null : _createConversation,
                child: _creating
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Создать диалог')),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _createConversation() async {
    final config = _selectedConfig;
    if (config == null) return;
    setState(() => _creating = true);
    try {
      final conversation = await context.read<ConversationProvider>().createConversation(
        title: 'Диалог с ${config.name}',
        type: ConversationType.xiaozhi,
        configId: config.id,
      );
      if (!mounted) return;
      Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => ChatScreen(conversation: conversation)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать диалог: $e')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }
}
