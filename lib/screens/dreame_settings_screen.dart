import 'package:flutter/material.dart';

import '../services/dreame_service.dart';

class DreameSettingsScreen extends StatefulWidget {
  const DreameSettingsScreen({super.key});

  @override
  State<DreameSettingsScreen> createState() => _DreameSettingsScreenState();
}

class _DreameSettingsScreenState extends State<DreameSettingsScreen> {
  final DreameService _service = DreameService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _countryController = TextEditingController(text: 'TR');
  final _languageController = TextEditingController(text: 'ru');

  String _region = 'eu';
  List<DreameDevice> _devices = [];
  List<DreameShortcut> _shortcuts = [];
  List<DreameRoom> _rooms = [];
  final Set<int> _selectedRoomIds = {};
  String? _selectedDeviceId;
  bool _loading = false;
  bool _obscurePassword = true;
  bool _connected = false;
  String? _error;

  static const _regions = <String, String>{
    'eu': 'Европа',
    'us': 'США',
    'cn': 'Китай',
    'ru': 'Россия',
    'sg': 'Сингапур',
    'in': 'Индия',
  };

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final saved = await _service.loadSavedSettings();
      if (!mounted) return;
      setState(() {
        _emailController.text = saved['email'] ?? '';
        _passwordController.text = saved['password'] ?? '';
        _region = _regions.containsKey(saved['region']) ? saved['region']! : 'eu';
        _countryController.text = saved['country'] ?? 'TR';
        _languageController.text = saved['language'] ?? 'ru';
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось прочитать сохранённые настройки: $e');
    }
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _devices = [];
      _shortcuts = [];
      _connected = false;
      _selectedDeviceId = null;
    });

    try {
      await _service.connect(
        email: _emailController.text,
        password: _passwordController.text,
        region: _region,
        country: _countryController.text,
        language: _languageController.text,
      );
      final devices = await _service.getDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _connected = true;
        _selectedDeviceId = devices.isEmpty ? null : devices.first.id;
      });
      if (devices.isNotEmpty) {
        await _loadDeviceData(devices.first.id);
      } else {
        setState(() => _error = 'Аккаунт подключён, но Dreamehome не вернул список устройств.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDeviceData(String deviceId) async {
    await _loadShortcuts(deviceId);
    final deviceMatches = _devices.where((device) => device.id == deviceId);
    if (deviceMatches.isEmpty) return;
    setState(() {
      _loading = true;
      _rooms = [];
      _selectedRoomIds.clear();
    });
    try {
      final rooms = await _service.getRooms(deviceMatches.first);
      if (mounted) setState(() => _rooms = rooms);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось загрузить комнаты с карты: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadShortcuts(String deviceId) async {
    setState(() {
      _loading = true;
      _shortcuts = [];
      _error = null;
    });
    try {
      final shortcuts = await _service.getShortcuts(deviceId);
      if (mounted) setState(() => _shortcuts = shortcuts);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось загрузить быстрые команды: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cleanSelectedRooms() async {
    final deviceId = _selectedDeviceId;
    final ids = _selectedRoomIds.toList()..sort();
    if (deviceId == null || ids.isEmpty) return;
    final names = _rooms.where((room) => ids.contains(room.id)).map((room) => room.name).join(', ');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Начать уборку комнат?'),
        content: Text('Робот начнёт уборку: $names'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Начать')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() { _loading = true; _error = null; });
    try {
      await _service.cleanSegments(deviceId, ids);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Команда уборки отправлена: $names')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось запустить уборку комнат: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runShortcut(DreameShortcut shortcut) async {
    final deviceId = _selectedDeviceId;
    if (deviceId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Запустить уборку?'),
        content: Text('Выполнить сценарий «${shortcut.name}» на роботе-пылесосе?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Запустить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.startShortcut(deviceId, shortcut.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Команда «${shortcut.name}» отправлена роботу.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось запустить сценарий: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _countryController.dispose();
    _languageController.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matchingDevices = _devices.where((d) => d.id == _selectedDeviceId);
    final selectedDevice = matchingDevices.isEmpty ? null : matchingDevices.first;
    return Scaffold(
      appBar: AppBar(title: const Text('Dreame L20 Ultra')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Подключение Dreamehome',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Данные аккаунта хранятся в защищённом хранилище Android. '
                    'Они не отправляются в XiaoZhi.',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(
                      labelText: 'E-mail / логин Dreamehome',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Пароль Dreamehome',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _region,
                    decoration: const InputDecoration(
                      labelText: 'Регион аккаунта',
                      border: OutlineInputBorder(),
                    ),
                    items: _regions.entries
                        .map((entry) => DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ))
                        .toList(),
                    onChanged: _loading ? null : (value) {
                      if (value != null) setState(() => _region = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _countryController,
                          textCapitalization: TextCapitalization.characters,
                          maxLength: 2,
                          decoration: const InputDecoration(
                            labelText: 'Код страны',
                            hintText: 'TR',
                            counterText: '',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _languageController,
                          maxLength: 2,
                          decoration: const InputDecoration(
                            labelText: 'Язык',
                            hintText: 'ru',
                            counterText: '',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _loading ? null : _connect,
                      icon: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.link),
                      label: Text(_loading ? 'Подключение…' : 'Подключить аккаунт'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
            ),
          ],
          if (_connected) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Аккаунт подключён',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_devices.isNotEmpty)
                      DropdownButtonFormField<String>(
                        value: _selectedDeviceId,
                        decoration: const InputDecoration(
                          labelText: 'Устройство',
                          border: OutlineInputBorder(),
                        ),
                        items: _devices
                            .map((device) => DropdownMenuItem(
                                  value: device.id,
                                  child: Text(
                                    '${device.name} · ${device.online ? 'в сети' : 'не в сети'}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                            .toList(),
                        onChanged: _loading ? null : (value) {
                          if (value != null) {
                            setState(() => _selectedDeviceId = value);
                            _loadDeviceData(value);
                          }
                        },
                      )
                    else
                      const Text('Устройства не найдены.'),
                    if (selectedDevice != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        selectedDevice.model,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Быстрые команды Dreamehome',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    const Text('Сценарии загружаются из аккаунта Dreamehome.'),
                    const SizedBox(height: 12),
                    if (_shortcuts.isEmpty && !_loading)
                      const Text('Сохранённые сценарии не найдены.')
                    else
                      ..._shortcuts.map(
                        (shortcut) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.play_circle_outline),
                          title: Text(shortcut.name),
                          subtitle: Text('ID: ${shortcut.id}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _loading ? null : () => _runShortcut(shortcut),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Уборка выбранных комнат',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    const Text('Комнаты считываются с активной карты робота. Можно выбрать несколько.'),
                    const SizedBox(height: 8),
                    if (_rooms.isEmpty && !_loading)
                      const Text('Комнаты на карте не найдены или карта пока недоступна.')
                    else
                      ..._rooms.map(
                        (room) => CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: _selectedRoomIds.contains(room.id),
                          title: Text(room.name),
                          subtitle: Text('ID комнаты: ${room.id}'),
                          onChanged: _loading
                              ? null
                              : (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      _selectedRoomIds.add(room.id);
                                    } else {
                                      _selectedRoomIds.remove(room.id);
                                    }
                                  });
                                },
                        ),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _loading || _selectedRoomIds.isEmpty
                            ? null
                            : _cleanSelectedRooms,
                        icon: const Icon(Icons.cleaning_services_outlined),
                        label: Text('Убрать выбранные комнаты (${_selectedRoomIds.length})'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Команды уборки используют текущие настройки мощности и подачи воды робота. '
            'Если на аккаунте включено дополнительное подтверждение входа (2FA/SMS), текущий способ '
            'авторизации может потребовать отдельного этапа подтверждения.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
