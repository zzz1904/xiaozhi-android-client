import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:ai_assistant/providers/conversation_provider.dart';
import 'package:ai_assistant/providers/config_provider.dart';
import 'package:ai_assistant/models/conversation.dart';
import 'package:ai_assistant/screens/chat_screen.dart';
import 'package:ai_assistant/screens/settings_screen.dart';
import 'package:ai_assistant/screens/conversation_type_screen.dart';
import 'package:ai_assistant/widgets/conversation_tile.dart';
import 'package:ai_assistant/widgets/slidable_delete_tile.dart';
import 'package:flutter/rendering.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final FocusNode _searchFocusNode = FocusNode();
  static const MethodChannel _assistantChannel = MethodChannel('xiaozhi/assistant');
  bool _assistantLaunchInProgress = false;
  bool _creatingConversation = false;

  @override
  void initState() {
    super.initState();
    _assistantChannel.setMethodCallHandler((call) async {
      if (call.method == 'assistantLaunch') {
        final pending = await _assistantChannel.invokeMethod<bool>(
          'consumeAssistantLaunch',
        );
        if (pending == true) _openAssistantVoice();
      }
      return null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pending = await _assistantChannel.invokeMethod<bool>(
          'consumeAssistantLaunch',
        );
        if (pending == true) _openAssistantVoice();
      } on PlatformException catch (e) {
        debugPrint('Не удалось получить запрос голосового помощника: $e');
      } on MissingPluginException {
        // Канал доступен только в Android-сборке с системным помощником.
      }
    });
  }

  Future<void> _openAssistantVoice() async {
    if (!mounted || _assistantLaunchInProgress) return;
    _assistantLaunchInProgress = true;
    try {
      final configProvider = context.read<ConfigProvider>();
      final conversationProvider = context.read<ConversationProvider>();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (!mounted) return;
        if (configProvider.isLoaded && conversationProvider.isLoaded) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      if (!configProvider.isLoaded || !conversationProvider.isLoaded) {
        throw Exception('Не удалось загрузить настройки приложения');
      }
      if (configProvider.xiaozhiConfigs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сначала подключите сервис XiaoZhi в настройках'),
          ),
        );
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
        return;
      }
      final config = configProvider.xiaozhiConfigs.first;
      final conversation = await conversationProvider.createConversation(
        title: 'Голосовой помощник XiaoZhi',
        type: ConversationType.xiaozhi,
        configId: config.id,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            conversation: conversation,
            assistantMode: true,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось запустить XiaoZhi: $e')),
        );
      }
    } finally {
      _assistantLaunchInProgress = false;
    }
  }

  Future<void> _createNewConversation() async {
    if (_creatingConversation) return;
    setState(() => _creatingConversation = true);
    try {
      final configProvider = context.read<ConfigProvider>();
      final conversationProvider = context.read<ConversationProvider>();

      // Дожидаемся загрузки сохранённых подключений и списка диалогов.
      for (var attempt = 0; attempt < 100; attempt++) {
        if (!mounted) return;
        if (configProvider.isLoaded && conversationProvider.isLoaded) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!mounted) return;
      if (!configProvider.isLoaded || !conversationProvider.isLoaded) {
        throw Exception('Не удалось загрузить настройки приложения');
      }

      if (configProvider.xiaozhiConfigs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Сначала подключите сервис XiaoZhi в настройках'),
          ),
        );
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
        return;
      }

      // Подключение одно, поэтому сразу используем его без экрана выбора.
      final config = configProvider.xiaozhiConfigs.first;
      final conversation = await conversationProvider.createConversation(
        title: 'Диалог с ${config.name}',
        type: ConversationType.xiaozhi,
        configId: config.id,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(conversation: conversation),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось создать диалог: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingConversation = false);
    }
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        // 点击页面任何地方时，让搜索框失去焦点
        _searchFocusNode.unfocus();
        // 同时关闭所有打开的删除按钮
        SlidableController.instance.closeCurrentTile();
      },
      child: Scaffold(
        extendBody: true,
        extendBodyBehindAppBar: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar:
            _selectedIndex == 1
                ? null
                : AppBar(
                  title: Text(
                    'Диалоги',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 28,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                  centerTitle: false,
                  titleSpacing: 20,
                  toolbarHeight: 65,
                  actions: [
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          splashColor: Colors.grey.withOpacity(0.1),
                          highlightColor: Colors.grey.withOpacity(0.1),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const SettingsScreen(),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Icon(
                              Icons.settings,
                              size: 26,
                              color: Colors.grey.shade700,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 0.5,
                                  offset: const Offset(0, 0.5),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildSearchBar(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
        floatingActionButton:
            _selectedIndex == 0
                ? Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 10,
                        spreadRadius: 0,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        spreadRadius: -2,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: FloatingActionButton(
                    onPressed: _creatingConversation ? null : _createNewConversation,
                    backgroundColor: Colors.black,
                    child: _creatingConversation
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.add, size: 30, color: Colors.white),
                    elevation: 0,
                    shape: const CircleBorder(),
                  ),
                )
                : null,
        bottomNavigationBar: null,
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 6,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: TextField(
            focusNode: _searchFocusNode,
            decoration: InputDecoration(
              hintText: 'Поиск по диалогам',
              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 16),
              prefixIcon: Container(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  Icons.search,
                  color: Colors.grey.shade500,
                  size: 22,
                ),
              ),
              suffixIcon: Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.mic_none_outlined,
                  color: Colors.grey.shade500,
                  size: 22,
                ),
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              focusColor: Theme.of(context).colorScheme.surface,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                vertical: 16,
                horizontal: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // Messages tab
    return Consumer<ConversationProvider>(
      builder: (context, provider, child) {
        final pinnedConversations = provider.pinnedConversations;
        final unpinnedConversations = provider.unpinnedConversations;

        return ListView(
          padding: EdgeInsets.only(
            bottom: 16 + MediaQuery.of(context).padding.bottom,
          ),
          children: [
            if (pinnedConversations.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 8,
                  bottom: 8,
                ),
                child: Text(
                  'Закреплённые',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Colors.grey,
                    fontSize: 15,
                    shadows: [
                      Shadow(
                        color: Color(0x40000000),
                        blurRadius: 0.5,
                        offset: Offset(0, 0.5),
                      ),
                    ],
                  ),
                ),
              ),
              ...pinnedConversations.map(
                (conversation) => _buildConversationTile(conversation),
              ),
            ],

            if (unpinnedConversations.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: pinnedConversations.isEmpty ? 8 : 16,
                  bottom: 8,
                ),
                child: const Text(
                  'Все диалоги',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Colors.grey,
                    fontSize: 15,
                    shadows: [
                      Shadow(
                        color: Color(0x40000000),
                        blurRadius: 0.5,
                        offset: Offset(0, 0.5),
                      ),
                    ],
                  ),
                ),
              ),
              ...unpinnedConversations.map(
                (conversation) => _buildConversationTile(conversation),
              ),
            ],

            if (pinnedConversations.isEmpty && unpinnedConversations.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(64.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              spreadRadius: 0,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.chat_bubble_outline,
                          size: 48,
                          color: Colors.grey.shade300,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Пока нет диалогов',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade500,
                          shadows: const [
                            Shadow(
                              color: Color(0x40000000),
                              blurRadius: 0.5,
                              offset: Offset(0, 0.5),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 5,
                              spreadRadius: 0,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.add_circle_outline,
                              size: 18,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Нажмите +, чтобы создать диалог',
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildConversationTile(Conversation conversation) {
    return SlidableDeleteTile(
      key: Key(conversation.id),
      onDelete: () {
        // 删除对话
        Provider.of<ConversationProvider>(
          context,
          listen: false,
        ).deleteConversation(conversation.id);

        // 显示撤销消息
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Диалог удалён'),
            backgroundColor: Colors.grey.shade800,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            margin: EdgeInsets.only(bottom: 70, left: 20, right: 20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            action: SnackBarAction(
              label: 'Отменить',
              textColor: Colors.white,
              onPressed: () {
                // 恢复被删除的对话
                Provider.of<ConversationProvider>(
                  context,
                  listen: false,
                ).restoreLastDeletedConversation();
              },
            ),
          ),
        );
      },
      onTap: () {
        // 直接导航到聊天页面
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(conversation: conversation),
          ),
        );
      },
      onLongPress: () {
        // 显示置顶等选项
        _showConversationOptions(conversation);
      },
      child: ConversationTile(
        conversation: conversation,
        onTap: null, // 不再需要处理点击
        onLongPress: null, // 不再需要处理长按
      ),
    );
  }

  void _showConversationOptions(Conversation conversation) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      elevation: 20,
      barrierColor: Colors.black.withOpacity(0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 5,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 1,
                      spreadRadius: 0,
                      offset: const Offset(0, 0.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 10,
                        spreadRadius: 0,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.06),
                              blurRadius: 4,
                              spreadRadius: 0,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          conversation.isPinned
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                          color: Colors.black,
                          size: 24,
                        ),
                      ),
                      title: Text(
                        conversation.isPinned ? 'Открепить' : 'Закреплённые',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        Provider.of<ConversationProvider>(
                          context,
                          listen: false,
                        ).togglePinConversation(conversation.id);
                      },
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 10,
                        spreadRadius: 0,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.1),
                              blurRadius: 4,
                              spreadRadius: 0,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.delete,
                          color: Colors.red,
                          size: 24,
                        ),
                      ),
                      title: const Text(
                        'Удалить диалог',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.red,
                        ),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        Provider.of<ConversationProvider>(
                          context,
                          listen: false,
                        ).deleteConversation(conversation.id);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Диалог удалён'),
                            backgroundColor: Colors.grey.shade800,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }
}
