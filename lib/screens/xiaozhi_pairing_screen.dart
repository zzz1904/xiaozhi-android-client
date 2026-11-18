import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/services/xiaozhi_ota_service.dart';

class XiaozhiPairingScreen extends StatefulWidget {
  const XiaozhiPairingScreen({super.key});

  @override
  State<XiaozhiPairingScreen> createState() => _XiaozhiPairingScreenState();
}

class _XiaozhiPairingScreenState extends State<XiaozhiPairingScreen> {
  final XiaozhiOtaService _otaService = XiaozhiOtaService();
  String? _activationCode;
  String? _activationMessage;
  String _status = 'Подготовка подключения...';
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPairing());
  }

  Future<void> _startPairing() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Подключаемся к серверу XiaoZhi...';
    });

    try {
      final provider = Provider.of<ConfigProvider>(context, listen: false);
      final identity = await provider.getXiaozhiIdentity();
      final deviceId = identity['deviceId']!;
      final clientId = identity['clientId']!;

      while (mounted) {
        setState(() => _status = 'Получаем параметры подключения...');
        final configuration = await _otaService.requestConfiguration(
          deviceId: deviceId,
          clientId: clientId,
        );

        final activation = configuration['activation'];
        if (activation is Map) {
          final code = (activation['code'] ?? '').toString();
          final challenge = (activation['challenge'] ?? '').toString();
          if (code.isEmpty || challenge.isEmpty) {
            throw const FormatException(
              'Сервер не прислал код или challenge для активации',
            );
          }

          if (mounted) {
            setState(() {
              _activationCode = code;
              _activationMessage =
                  (activation['message'] ?? 'Введите этот код в консоли XiaoZhi')
                      .toString();
              _status = 'Ожидаем привязки устройства в консоли...';
            });
          }

          var activated = false;
          for (var attempt = 0; attempt < 10 && mounted; attempt++) {
            await Future.delayed(const Duration(seconds: 3));
            if (!mounted) return;

            final statusCode = await _otaService.activate(
              deviceId: deviceId,
              clientId: clientId,
            );
            if (statusCode == 200) {
              activated = true;
              if (mounted) {
                setState(() => _status = 'Устройство привязано. Получаем настройки...');
              }
              break;
            }
            if (statusCode == 202) {
              if (mounted) {
                setState(() => _status = 'Код ожидает подтверждения в консоли...');
              }
            } else {
              if (mounted) {
                setState(() => _status = 'Сервер пока не подтвердил привязку. Повторяем...');
              }
              await Future.delayed(const Duration(seconds: 7));
            }
          }

          if (!activated) {
            continue;
          }
          // После успешной привязки повторно запрашиваем OTA и получаем актуальный токен.
          continue;
        }

        final websocket = configuration['websocket'];
        if (websocket is! Map) {
          throw const FormatException(
            'Сервер не прислал настройки WebSocket. Проверьте, поддерживает ли сервис этот тип подключения.',
          );
        }
        final websocketUrl = (websocket['url'] ?? '').toString();
        final token = (websocket['token'] ?? '').toString();
        if (websocketUrl.isEmpty || token.isEmpty) {
          throw const FormatException(
            'В ответе XiaoZhi отсутствует адрес WebSocket или токен',
          );
        }

        await provider.addXiaozhiConfig(
          'Официальная консоль XiaoZhi',
          websocketUrl,
          customMacAddress: deviceId,
          token: token,
          clientId: clientId,
        );

        if (!mounted) return;
        setState(() {
          _status = 'Подключение настроено';
          _busy = false;
        });
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
        _status = 'Не удалось подключиться';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Подключение к консоли XiaoZhi')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_outlined, size: 64),
              const SizedBox(height: 20),
              const Text(
                'Официальная консоль XiaoZhi',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Откройте xiaozhi.me на телефоне или компьютере и войдите в свою учётную запись.',
                textAlign: TextAlign.center,
              ),
              if (_activationCode != null) ...[
                const SizedBox(height: 28),
                const Text(
                  'Код привязки устройства',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 18,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SelectableText(
                        _activationCode!,
                        style: const TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 6,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Скопировать код',
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: _activationCode!),
                        ),
                        icon: const Icon(Icons.copy),
                      ),
                    ],
                  ),
                ),
                if (_activationMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(_activationMessage!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 12),
                const Text(
                  'В консоли выберите «Добавить устройство» и введите этот код. Не сообщайте его посторонним.',
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              if (_busy) const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(_status, textAlign: TextAlign.center),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _startPairing,
                  child: const Text('Повторить'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
