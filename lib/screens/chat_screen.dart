import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math';
import 'package:provider/provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/models/message.dart';
import 'package:ai_assistant/models/xiaozhi_config.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/services/xiaozhi_service.dart';
import 'package:ai_assistant/widgets/message_bubble.dart';
import 'package:ai_assistant/screens/voice_call_screen.dart';
import 'dart:async';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  final bool assistantMode;

  const ChatScreen({
    super.key,
    required this.conversation,
    this.assistantMode = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  bool _handsFreeReady = false;
  XiaozhiService? _xiaozhiService; // 保持XiaozhiService实例
  Timer? _connectionCheckTimer; // 添加定时器检查连接状态
  Timer? _autoReconnectTimer; // 自动重连定时器
  bool _backgroundCloseStarted = false;
  Future<void>? _serviceShutdownFuture;

  // 语音输入相关
  bool _isVoiceInputMode = false;
  bool _isRecording = false;
  bool _isCancelling = false;
  double _startDragY = 0.0;
  final double _cancelThreshold = 50.0; // 上滑超过这个距离认为是取消
  Timer? _waveAnimationTimer;
  final List<double> _waveHeights = List.filled(20, 0.0);
  double _minWaveHeight = 5.0;
  double _maxWaveHeight = 30.0;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 设置状态栏为透明并使图标为黑色
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    // 在帧绘制后再次设置系统UI样式，避免被覆盖
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );

      Provider.of<ConversationProvider>(
        context,
        listen: false,
      ).markConversationAsRead(widget.conversation.id);

      // 如果是小智对话，初始化服务
      if (widget.conversation.type == ConversationType.xiaozhi) {
        _initXiaozhiService();
        // 添加定时器定期检查连接状态
        _connectionCheckTimer = Timer.periodic(const Duration(seconds: 2), (
          timer,
        ) {
          if (mounted && _xiaozhiService != null) {
            final wasConnected = _xiaozhiService!.isConnected;

            // 刷新UI
            setState(() {});

            // 如果状态从连接变为断开，尝试自动重连
            if (wasConnected &&
                !_xiaozhiService!.isConnected &&
                _autoReconnectTimer == null) {
              print('检测到连接断开，准备自动重连');
              _scheduleReconnect();
            }
          }
        });

        // 默认启用语音输入模式 (针对小智对话)
        setState(() {
          _isVoiceInputMode = true;
        });
      }
    });
  }

  // 安排自动重连
  void _scheduleReconnect() {
    // 取消现有重连定时器
    _autoReconnectTimer?.cancel();

    // 创建新的重连定时器，5秒后尝试重连
    _autoReconnectTimer = Timer(const Duration(seconds: 5), () async {
      print('正在尝试自动重连...');
      if (_xiaozhiService != null && !_xiaozhiService!.isConnected && mounted) {
        try {
          await _xiaozhiService!.disconnect();
          await _xiaozhiService!.connect();

          setState(() {});
          print('自动重连 ${_xiaozhiService!.isConnected ? "成功" : "失败"}');

          // 如果重连失败，则继续尝试重连
          if (!_xiaozhiService!.isConnected) {
            _scheduleReconnect();
          } else {
            _autoReconnectTimer = null;
          }
        } catch (e) {
          print('自动重连出错: $e');
          _scheduleReconnect(); // 出错后继续尝试
        }
      } else {
        _autoReconnectTimer = null;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // При уходе приложения в фон закрываем открытый чат и возвращаемся
    // к списку диалогов. Состояние inactive не используем: оно бывает
    // при системных уведомлениях и временных перекрытиях экрана.
    if (state == AppLifecycleState.paused) {
      _closeChatForBackground();
    }
  }

  Future<void> _closeChatForBackground() async {
    if (_backgroundCloseStarted || !mounted) return;
    _backgroundCloseStarted = true;

    // Не ждём сетевого отключения: при сворачивании приложение может
    // быть приостановлено Android раньше, чем disconnect завершится.
    // Сначала сразу закрываем экран чата и возвращаемся к списку диалогов.
    Navigator.of(context).popUntil((route) => route.isFirst);

    // Остановка микрофона, воспроизведения и соединения выполняется отдельно.
    // dispose() также использует тот же Future, поэтому очистка не дублируется.
    unawaited(_shutdownXiaozhiService());
  }

  Future<void> _shutdownXiaozhiService() {
    return _serviceShutdownFuture ??= _performXiaozhiShutdown();
  }

  Future<void> _performXiaozhiShutdown() async {
    final service = _xiaozhiService;
    if (service == null) return;
    try {
      service.setAssistantAutoListenAfterTts(false);
      await service.switchToChatMode();
      await service.stopPlayback();
      await service.disconnect();
    } catch (e) {
      debugPrint('Не удалось полностью закрыть сессию XiaoZhi: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _scrollController.dispose();
    _connectionCheckTimer?.cancel();
    _autoReconnectTimer?.cancel();
    _waveAnimationTimer?.cancel();

    // Гарантированно останавливаем микрофон, звук и соединение.
    _shutdownXiaozhiService();

    super.dispose();
  }

  // 初始化小智服务
  Future<void> _initXiaozhiService() async {
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);
    final xiaozhiConfig = configProvider.xiaozhiConfigs.firstWhere(
      (config) => config.id == widget.conversation.configId,
    );

    _xiaozhiService = XiaozhiService(
      websocketUrl: xiaozhiConfig.websocketUrl,
      macAddress: xiaozhiConfig.macAddress,
      token: xiaozhiConfig.token,
      clientId: xiaozhiConfig.clientId,
      sessionId: widget.conversation.id,
    );

    // 添加消息监听器
    _xiaozhiService!.addListener(_handleXiaozhiMessage);
    if (widget.assistantMode) {
      _xiaozhiService!.setAssistantAutoListenAfterTts(true);
    }

    // Подключение
    try {
      if (widget.assistantMode) {
        // Сначала ждём hello: сервер должен выдать свою session_id.
        // Только после этого включаем микрофон и отправляем listen/start.
        await _xiaozhiService!.connectAndWaitForHello();
        await _xiaozhiService!.switchToVoiceCallMode();
        await _xiaozhiService!.startListeningCall();
      } else {
        await _xiaozhiService!.connect();
      }

      if (mounted) {
        setState(() {
          _handsFreeReady = widget.assistantMode;
        });
      }
    } catch (e) {
      if (mounted) {
        _showCustomSnackbar('Не удалось запустить XiaoZhi: $e');
      }
    }
  }

  Future<void> _restartAssistantListening() async {
    if (_xiaozhiService == null || !mounted) return;
    try {
      _xiaozhiService!.setAssistantAutoListenAfterTts(true);
      await _xiaozhiService!.startListeningCall();
      if (mounted) setState(() => _handsFreeReady = true);
    } catch (e) {
      _showCustomSnackbar('Не удалось включить микрофон: $e');
    }
  }

  // 处理小智消息
  void _handleXiaozhiMessage(XiaozhiServiceEvent event) {
    if (!mounted) return;

    final conversationProvider = Provider.of<ConversationProvider>(
      context,
      listen: false,
    );

    if (event.type == XiaozhiServiceEventType.textMessage) {
      // 直接使用文本内容
      String content = event.data as String;
      print('收到消息内容: $content');

      // 忽略空消息
      if (content.isNotEmpty) {
        conversationProvider.addMessage(
          conversationId: widget.conversation.id,
          role: MessageRole.assistant,
          content: content,
        );
      }
    } else if (event.type == XiaozhiServiceEventType.userMessage) {
      // 处理用户的语音识别文本
      String content = event.data as String;
      print('收到用户语音识别内容: $content');

      // 只有在语音输入模式下才添加用户消息
      if (content.isNotEmpty && _isVoiceInputMode) {
        // 语音消息可能有延迟，使用Future.microtask确保UI已更新
        Future.microtask(() {
          conversationProvider.addMessage(
            conversationId: widget.conversation.id,
            role: MessageRole.user,
            content: content,
          );
        });
      }
    } else if (event.type == XiaozhiServiceEventType.voiceCallEnd &&
        event.data == 'silence_timeout') {
      setState(() => _handsFreeReady = false);
    } else if (event.type == XiaozhiServiceEventType.connected ||
        event.type == XiaozhiServiceEventType.disconnected) {
      // 当连接状态发生变化时，更新UI
      setState(() {});
    }
  }

@override
  Widget build(BuildContext context) {
    // 确保状态栏设置正确
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        toolbarHeight: 70,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        actions: [
          if (widget.conversation.type == ConversationType.xiaozhi &&
              !widget.assistantMode)
            Container(
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _navigateToVoiceCall,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.phone, color: Colors.black, size: 16),
                    ),
                  ),
                ),
              ),
            ),
        ],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black, size: 26),
          onPressed: () {
            // 返回前停止播放
            if (_xiaozhiService != null) {
              _xiaozhiService!.stopPlayback();
            }
            Navigator.of(context).pop();
          },
        ),
        title: Text(widget.conversation.title),
      ),
      body: Column(
        children: [
          if (widget.conversation.type == ConversationType.xiaozhi)
            _buildXiaozhiInfo(),
          Expanded(child: _buildMessageList()),
          if (widget.conversation.type == ConversationType.xiaozhi)
            _buildInputArea()
          else
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Сохранённый архивный диалог. Отправка новых сообщений отключена.'),
            ),
        ],
      ),
    );
  }

  Widget _buildXiaozhiInfo() {
    final configProvider = Provider.of<ConfigProvider>(context);
    final xiaozhiConfig = configProvider.xiaozhiConfigs.firstWhere(
      (config) => config.id == widget.conversation.configId,
      orElse:
          () => XiaozhiConfig(
            id: '',
            name: 'Неизвестный сервис',
            websocketUrl: '',
            macAddress: '',
            token: '',
          ),
    );

    final bool isConnected = _xiaozhiService?.isConnected ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 6,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 连接状态指示器
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isConnected ? Colors.green : Colors.red,
              boxShadow: [
                BoxShadow(
                  color: (isConnected ? Colors.green : Colors.red).withOpacity(
                    0.4,
                  ),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isConnected ? 'Подключено' : 'Не подключено',
            style: TextStyle(
              fontSize: 13,
              color: isConnected ? Colors.green : Colors.red,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 12),

          // 分隔线
          Container(width: 1, height: 16, color: Colors.grey.withOpacity(0.3)),
          const SizedBox(width: 12),

          // WebSocket信息
          Expanded(
            child: Text(
              '${xiaozhiConfig.websocketUrl}',
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          if (xiaozhiConfig.macAddress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 4,
                      spreadRadius: 0,
                      offset: const Offset(0, 1),
                    ),
                    BoxShadow(
                      color: Colors.white.withOpacity(0.9),
                      blurRadius: 3,
                      spreadRadius: 0,
                      offset: const Offset(0, -1),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.devices, size: 12, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      '${xiaozhiConfig.macAddress}',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return Consumer<ConversationProvider>(
      builder: (context, provider, child) {
        final messages = provider.getMessages(widget.conversation.id);

        if (messages.isEmpty) {
          return Center(
            child: Text(
              'Начать новый диалог',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 16),
            ),
          );
        }

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          reverse: true,
          itemCount: messages.length + (_isLoading ? 1 : 0),
          cacheExtent: 1000.0,
          addRepaintBoundaries: true,
          addAutomaticKeepAlives: true,
          physics: const ClampingScrollPhysics(),
          itemBuilder: (context, index) {
            if (_isLoading && index == 0) {
              return MessageBubble(
                message: Message(
                  id: 'loading',
                  conversationId: '',
                  role: MessageRole.assistant,
                  content: 'Думаю...',
                  timestamp: DateTime.now(),
                ),
                isThinking: true,
                conversationType: widget.conversation.type,
              );
            }

            final adjustedIndex = _isLoading ? index - 1 : index;
            final message = messages[messages.length - 1 - adjustedIndex];

            return RepaintBoundary(
              child: MessageBubble(
                key: ValueKey(message.id),
                message: message,
                conversationType: widget.conversation.type,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInputArea() {
    if (widget.assistantMode) {
      return _buildAssistantListeningArea();
    }

    final bool hasText = _textController.text.trim().isNotEmpty;

    // 根据状态决定显示文本输入还是语音输入
    if (_isVoiceInputMode &&
        widget.conversation.type == ConversationType.xiaozhi) {
      return _buildVoiceInputArea();
    } else {
      return _buildTextInputArea(hasText);
    }
  }

  Widget _buildAssistantListeningArea() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        14 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            Icons.mic,
            color: _handsFreeReady ? Colors.green : Colors.grey,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _handsFreeReady
                  ? 'Слушаю вас. После ответа снова продолжу слушать.'
                  : (_xiaozhiService?.isConnected == true
                      ? 'Микрофон выключен после 10 секунд тишины.'
                      : 'Подключение к XiaoZhi...'),
              style: const TextStyle(
                color: Color(0xFF374151),
                fontSize: 14,
              ),
            ),
          ),
          if (!_handsFreeReady && _xiaozhiService?.isConnected == true)
            IconButton(
              tooltip: 'Включить микрофон',
              onPressed: _restartAssistantListening,
              icon: const Icon(Icons.mic, color: Colors.green),
            ),
          IconButton(
            tooltip: 'Завершить',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // 文本输入区域
  Widget _buildTextInputArea(bool hasText) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 16,
        top: 16,
        right: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7F9),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.07),
                  blurRadius: 8,
                  spreadRadius: 0,
                  offset: const Offset(0, 3),
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.8),
                  blurRadius: 5,
                  spreadRadius: 0,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: 'Введите сообщение...',
                      hintStyle: TextStyle(
                        color: Color(0xFF9CA3AF),
                        fontSize: 16,
                      ),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 14,
                      ),
                    ),
                    style: const TextStyle(
                      color: Color(0xFF1F2937),
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                _buildSendButton(hasText),
                if (widget.conversation.type == ConversationType.xiaozhi &&
                    !hasText)
                  IconButton(
                    icon: const Icon(
                      Icons.mic,
                      color: Color.fromARGB(255, 108, 108, 112),
                      size: 24,
                    ),
                    onPressed: () {
                      setState(() {
                        _isVoiceInputMode = true;
                      });
                    },
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    constraints: const BoxConstraints(),
                    splashRadius: 22,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 语音输入区域
  Widget _buildVoiceInputArea() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            spreadRadius: 0,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        left: 16,
        top: 16,
        right: 16,
        bottom: 16 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: GestureDetector(
              onLongPressStart: (details) {
                setState(() {
                  _isRecording = true;
                  _isCancelling = false;
                  _startDragY = details.globalPosition.dy;
                });
                _startRecording();
                _startWaveAnimation();
              },
              onLongPressMoveUpdate: (details) {
                // 计算垂直移动距离
                final double dragDistance =
                    _startDragY - details.globalPosition.dy;

                // 如果上滑超过阈值，标记为取消状态
                if (dragDistance > _cancelThreshold && !_isCancelling) {
                  setState(() {
                    _isCancelling = true;
                  });
                  // 震动反馈
                  HapticFeedback.mediumImpact();
                } else if (dragDistance <= _cancelThreshold && _isCancelling) {
                  setState(() {
                    _isCancelling = false;
                  });
                  // 震动反馈
                  HapticFeedback.lightImpact();
                }
              },
              onLongPressEnd: (details) {
                final wasRecording = _isRecording;
                final wasCancelling = _isCancelling;

                setState(() {
                  _isRecording = false;
                });

                _stopWaveAnimation();

                if (wasRecording) {
                  if (wasCancelling) {
                    _cancelRecording();
                  } else {
                    _stopRecording();
                  }
                }
              },
              child: Container(
                height: 54,
                decoration: BoxDecoration(
                  color:
                      _isRecording
                          ? _isCancelling
                              ? Colors.red.shade50
                              : Colors.blue.shade50
                          : const Color(0xFFF5F7F9),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.07),
                      blurRadius: 8,
                      spreadRadius: 0,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 波纹动画效果
                    if (_isRecording && !_isCancelling)
                      _buildWaveAnimationIndicator(),

                    // 文字提示
                    Center(
                      child: Text(
                        _isRecording
                            ? _isCancelling
                                ? "Отпустите, чтобы отменить"
                                : "Отпустите для отправки, проведите вверх для отмены"
                            : "Удерживайте для записи",
                        style: TextStyle(
                          color:
                              _isRecording
                                  ? _isCancelling
                                      ? Colors.red
                                      : Colors.blue.shade700
                                  : const Color.fromARGB(255, 9, 9, 9),
                          fontSize: 16,
                          fontWeight:
                              _isRecording
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 键盘按钮 (切换回文本模式)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  spreadRadius: 0,
                  offset: const Offset(0, 2),
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.8),
                  blurRadius: 4,
                  spreadRadius: 0,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              shape: CircleBorder(),
              child: InkWell(
                borderRadius: BorderRadius.circular(25),
                onTap: () {
                  // 如果正在录音，先取消录音
                  if (_isRecording) {
                    _cancelRecording();
                    _stopWaveAnimation();
                  }
                  // 切换回文本输入模式
                  setState(() {
                    _isVoiceInputMode = false;
                    _isRecording = false;
                    _isCancelling = false;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Icon(
                    Icons.keyboard,
                    color: Colors.grey.shade700,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSendButton(bool hasText) {
    return IconButton(
      key: const ValueKey('send_button'),
      icon: Icon(
        Icons.send_rounded,
        color: hasText ? Colors.black : const Color(0xFFC4C9D2),
        size: 24,
      ),
      onPressed: hasText ? _sendMessage : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      constraints: const BoxConstraints(),
      splashRadius: 22,
    );
  }

  // 开始录音
  void _startRecording() async {
    if (widget.conversation.type != ConversationType.xiaozhi ||
        _xiaozhiService == null) {
      _showCustomSnackbar('Голосовой ввод доступен только в диалогах Xiaozhi');
      setState(() {
        _isVoiceInputMode = false;
      });
      return;
    }

    try {
      // 震动反馈
      HapticFeedback.mediumImpact();

      // 开始录音
      await _xiaozhiService!.startListening();
    } catch (e) {
      print('开始录音失败: $e');
      _showCustomSnackbar('Не удалось начать запись: ${e.toString()}');
      setState(() {
        _isRecording = false;
        _isVoiceInputMode = false;
      });
    }
  }

  // 停止录音并发送
  void _stopRecording() async {
    try {
      setState(() {
        _isLoading = true;
        _isRecording = false;
        // 不要立即关闭语音输入模式，让用户可以看到识别结果
        // _isVoiceInputMode = false;
      });

      // 震动反馈
      HapticFeedback.mediumImpact();

      // 停止录音
      await _xiaozhiService?.stopListening();

      _scrollToBottom();
    } catch (e) {
      print('停止录音失败: $e');
      _showCustomSnackbar('Не удалось отправить аудио: ${e.toString()}');

      // 出错时关闭语音输入模式
      setState(() {
        _isVoiceInputMode = false;
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 取消录音
  void _cancelRecording() async {
    try {
      setState(() {
        _isRecording = false;
      });

      // 震动反馈
      HapticFeedback.heavyImpact();

      // 取消录音
      await _xiaozhiService?.abortListening();

      // 使用自定义的拟物化提示，显示在顶部且带有圆角
      _showCustomSnackbar('Отправка отменена');
    } catch (e) {
      print('取消录音失败: $e');
    }
  }

  // 显示自定义Snackbar
  void _showCustomSnackbar(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final snackBar = SnackBar(
      content: Text(
        message,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black.withOpacity(0.7),
      duration: const Duration(seconds: 2),
      margin: EdgeInsets.only(
        bottom: MediaQuery.of(context).size.height - 120,
        left: 16,
        right: 16,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
    );

    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }

void _sendMessage() async {
    final message = _textController.text.trim();
    if (message.isEmpty || _isLoading) return;

    _textController.clear();

    final conversationProvider = Provider.of<ConversationProvider>(
      context,
      listen: false,
    );

    // Add user message
    await conversationProvider.addMessage(
      conversationId: widget.conversation.id,
      role: MessageRole.user,
      content: message,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    _scrollToBottom();

    try {

        // 确保服务已连接
        if (_xiaozhiService == null) {
          await _initXiaozhiService();
        } else if (!_xiaozhiService!.isConnected) {
          // 如果未连接，尝试重新连接
          print('聊天屏幕: 服务未连接，尝试重新连接');
          await _xiaozhiService!.connect();

          // 如果重连失败，提示用户
          if (!_xiaozhiService!.isConnected) {
            throw Exception("Не удалось подключиться к Xiaozhi. Проверьте интернет и настройки сервиса.");
          }

          // 刷新UI显示连接状态
          setState(() {});
        }

        // 发送消息
        await _xiaozhiService!.sendTextMessage(message);
      
    } catch (e) {
      print('聊天屏幕: 发送消息错误: $e');

      if (!mounted) return;

      // Add error message
      await conversationProvider.addMessage(
        conversationId: widget.conversation.id,
        role: MessageRole.assistant,
        content: 'Произошла ошибка: ${e.toString()}',
      );
    } finally {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _navigateToVoiceCall() {
    final configProvider = Provider.of<ConfigProvider>(context, listen: false);
    final xiaozhiConfig = configProvider.xiaozhiConfigs.firstWhere(
      (config) => config.id == widget.conversation.configId,
    );

    // 导航前停止当前音频播放
    if (_xiaozhiService != null) {
      _xiaozhiService!.stopPlayback();
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => VoiceCallScreen(
              conversation: widget.conversation,
              xiaozhiConfig: xiaozhiConfig,
            ),
      ),
    ).then((_) {
      // 页面返回后，确保重新初始化服务以恢复正常对话功能
      if (_xiaozhiService != null &&
          widget.conversation.type == ConversationType.xiaozhi) {
        // 重新连接服务
        _xiaozhiService!.connect();
      }
    });
  }

  // 启动波形动画
  void _startWaveAnimation() {
    _waveAnimationTimer?.cancel();
    _waveAnimationTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_isRecording && !_isCancelling) {
        setState(() {
          for (int i = 0; i < _waveHeights.length; i++) {
            _waveHeights[i] = 0.5 + _random.nextDouble() * 0.5;
          }
        });
      }
    });
  }

  // 停止波形动画
  void _stopWaveAnimation() {
    _waveAnimationTimer?.cancel();
    _waveAnimationTimer = null;
  }

  // 构建波形动画指示器
  Widget _buildWaveAnimationIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(
          16,
          (index) => AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 3,
            height: 20 * _waveHeights[index],
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.6),
              borderRadius: BorderRadius.circular(1.5),
            ),
            curve: Curves.easeInOut,
          ),
        ),
      ),
    );
  }

  // 显示图片选择器选项
}
