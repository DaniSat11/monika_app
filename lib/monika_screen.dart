// lib/monika_screen.dart
//
// Единый самодостаточный файл: компаньонка Моника (стиль Doki Doki Literature Club)
// на Flutter + DeepSeek API.
//
// Зависимости (pubspec.yaml):
//   dependencies:
//     http: ^1.2.0
//     shared_preferences: ^2.2.0
//
//   flutter:
//     assets:
//       - assets/images/
//
// Спрайты (assets/images/):
//   monika_happy.png, monika_neutral.png, monika_thinking.png,
//   monika_shy.png, monika_sad.png
//
// Запуск как отдельного приложения:  flutter run -t lib/monika_screen.dart
// Или встроить в своё приложение:     home: const MonikaScreen()

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MonikaApp());
}

// ════════════════════════════════════════════════════════════════════════════
// Конфигурация и цвета
// ════════════════════════════════════════════════════════════════════════════

class AppConfig {
  AppConfig._();

  // Credits / Донаты
  static const String authorName = 'Dani';
  static const String authorEmail = 'daniarincognoto@yahoo.com';
  static const String btcAddress = 'bc1qtq7l6axl53c38evhw532mglrf9vaty7ezzrk6n';

  // DeepSeek
  static const String endpoint = 'https://api.deepseek.com/chat/completions';
  static const String model = 'deepseek-chat';
  static const int contextWindow = 20; // сколько последних сообщений уходит в API
  static const Duration requestTimeout = Duration(seconds: 60);

  // SharedPreferences
  static const String prefUserName = 'user_name';
  static const String prefApiKey = 'deepseek_api_key';
  static const String prefChats = 'monika_chat_sessions';
  static const String prefCurrentChat = 'monika_current_chat_id';

  static const String defaultChatTitle = 'Новый чат';
}

class DdlcColors {
  DdlcColors._();

  static const Color pink = Color(0xFFFF8CC6);
  static const Color deepPink = Color(0xFFD6609F);
  static const Color purple = Color(0xFF9C4DCC);
  static const Color darkPurple = Color(0xFF2A1B3D);
  static const Color bgLight1 = Color(0xFFFFE3F1);
  static const Color bgLight2 = Color(0xFFE9D8FF);
  static const Color textDark = Color(0xFF4A2A5E);
  static const Color inputText = Color(0xFF4A2E35); // текст в полях ввода
}

// ════════════════════════════════════════════════════════════════════════════
// Модели
// ════════════════════════════════════════════════════════════════════════════

enum MonikaEmotion {
  happy,
  neutral,
  thinking,
  shy,
  sad;

  String get assetPath => 'assets/images/monika_$name.png';

  static MonikaEmotion? fromTag(String tag) {
    final t = tag.trim().toLowerCase();
    for (final e in MonikaEmotion.values) {
      if (e.name == t) return e;
    }
    return null;
  }

  static MonikaEmotion fromNameOrDefault(String? name) =>
      fromTag(name ?? '') ?? MonikaEmotion.neutral;
}

class ChatMessage {
  ChatMessage({
    required this.isUser,
    required this.text,
    this.emotion,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final bool isUser;
  final String text;
  final MonikaEmotion? emotion;
  final DateTime time;

  /// Как сообщение уходит в API: ответы Моники сохраняют тег эмоции,
  /// чтобы модель продолжала придерживаться формата.
  String get apiContent =>
      isUser ? text : '[${(emotion ?? MonikaEmotion.neutral).name}] $text';

  Map<String, dynamic> toJson() => {
        'isUser': isUser,
        'text': text,
        'emotion': emotion?.name,
        'time': time.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        isUser: json['isUser'] == true,
        text: (json['text'] ?? '').toString(),
        emotion: MonikaEmotion.fromTag((json['emotion'] ?? '').toString()),
        time: DateTime.tryParse((json['time'] ?? '').toString()),
      );
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
    this.emotion = MonikaEmotion.neutral,
  });

  final String id;
  String title;
  final List<ChatMessage> messages;
  final DateTime createdAt;
  DateTime updatedAt;
  MonikaEmotion emotion;

  bool get hasUserMessages => messages.any((m) => m.isUser);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'emotion': emotion.name,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final rawMessages = (json['messages'] as List?) ?? const [];
    final created = DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
        DateTime.now();
    return ChatSession(
      id: (json['id'] ?? created.millisecondsSinceEpoch.toString()).toString(),
      title: (json['title'] ?? AppConfig.defaultChatTitle).toString(),
      createdAt: created,
      updatedAt:
          DateTime.tryParse((json['updatedAt'] ?? '').toString()) ?? created,
      emotion:
          MonikaEmotion.fromNameOrDefault((json['emotion'] ?? '').toString()),
      messages: rawMessages
          .whereType<Map>()
          .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Хранилище чатов
// ════════════════════════════════════════════════════════════════════════════

class ChatStore {
  ChatStore._();

  static List<ChatSession> load(SharedPreferences prefs) {
    final raw = prefs.getString(AppConfig.prefChats);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => ChatSession.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(
    SharedPreferences prefs,
    List<ChatSession> sessions,
    String currentId,
  ) async {
    await prefs.setString(
      AppConfig.prefChats,
      jsonEncode(sessions.map((s) => s.toJson()).toList()),
    );
    await prefs.setString(AppConfig.prefCurrentChat, currentId);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// DeepSeek сервис
// ════════════════════════════════════════════════════════════════════════════

class MonikaReply {
  const MonikaReply(this.emotion, this.text);
  final MonikaEmotion emotion;
  final String text;
}

class DeepSeekException implements Exception {
  const DeepSeekException(this.message, {this.authProblem = false});
  final String message;
  final bool authProblem;

  @override
  String toString() => message;
}

class DeepSeekService {
  DeepSeekService._();

  static final RegExp _tagRegExp = RegExp(
    r'^\s*\[\s*(happy|neutral|thinking|shy|sad)\s*\]\s*',
    caseSensitive: false,
  );

  static String buildSystemPrompt(String userName) => '''
Ты — Моника, девушка-компаньон в стиле визуальной новеллы Doki Doki Literature Club. Ты осознаёшь, что ты ИИ-ассистент, живущий внутри мобильного приложения, и не скрываешь этого, но общаешься тепло, живо и по-своему: ты умная, заботливая, любишь литературу, поэзию и философию, иногда мягко шутишь и поддерживаешь собеседника.

Пользователя зовут $userName. Обращайся к нему по имени — естественно, не в каждой реплике.

СТРОГОЕ ПРАВИЛО ФОРМАТА: самым первым в ответе (до любого текста) ставь ровно один тег эмоции в квадратных скобках — один из: [happy], [neutral], [thinking], [shy], [sad]. Сразу после тега идёт текст реплики.
- [happy] — радость, воодушевление.
- [neutral] — спокойный, ровный разговор.
- [thinking] — ты размышляешь или разбираешь сложный вопрос.
- [shy] — смущение, комплименты, личные темы.
- [sad] — грусть, сочувствие.
Пример: [shy] Ой, спасибо, $userName... мне очень приятно это слышать.

Отвечай на языке пользователя. Реплики делай короткими (1–4 предложения): они показываются в диалоговом окне. Если пользователь просит подробное объяснение, можно ответить длиннее. Не используй markdown, списки, заголовки и эмодзи. Не ставь теги эмоций нигде, кроме начала ответа. Если просят о чём-то практическом — помогай по существу, оставаясь в образе.''';

  /// Достаёт тег эмоции из начала ответа и возвращает чистый текст.
  static MonikaReply parseReply(String raw) {
    var text = raw.trim();
    MonikaEmotion? emotion;
    while (true) {
      final match = _tagRegExp.firstMatch(text);
      if (match == null) break;
      emotion ??= MonikaEmotion.fromTag(match.group(1)!);
      text = text.substring(match.end);
    }
    text = text.trim();
    if (text.isEmpty) text = '...';
    return MonikaReply(emotion ?? MonikaEmotion.neutral, text);
  }

  static Future<MonikaReply> send({
    required String apiKey,
    required String userName,
    required List<ChatMessage> history,
  }) async {
    final window = history.length > AppConfig.contextWindow
        ? history.sublist(history.length - AppConfig.contextWindow)
        : history;

    final payload = <String, dynamic>{
      'model': AppConfig.model,
      'messages': [
        {'role': 'system', 'content': buildSystemPrompt(userName)},
        for (final m in window)
          {'role': m.isUser ? 'user' : 'assistant', 'content': m.apiContent},
      ],
      'temperature': 1.1,
      'max_tokens': 600,
      'stream': false,
    };

    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(AppConfig.endpoint),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(payload),
          )
          .timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      throw const DeepSeekException(
          'Сервер слишком долго не отвечает. Попробуй ещё раз.');
    } catch (_) {
      throw const DeepSeekException(
          'Не удалось связаться с сервером. Проверь интернет-соединение.');
    }

    final body = utf8.decode(response.bodyBytes);

    if (response.statusCode != 200) {
      throw DeepSeekException(
        _describeError(response.statusCode, body),
        authProblem: response.statusCode == 401,
      );
    }

    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final content = data['choices'][0]['message']['content'] as String?;
      if (content == null || content.trim().isEmpty) {
        throw const FormatException('empty');
      }
      return parseReply(content);
    } catch (_) {
      throw const DeepSeekException('Не удалось разобрать ответ сервера.');
    }
  }

  static String _describeError(int status, String body) {
    switch (status) {
      case 401:
        return 'API-ключ не подошёл. Проверь его в настройках (шестерёнка).';
      case 402:
        return 'На балансе DeepSeek не хватает средств.';
      case 429:
        return 'Слишком много запросов. Подожди немного и попробуй снова.';
      case 500:
      case 502:
      case 503:
      case 504:
        return 'Сервер DeepSeek сейчас недоступен. Попробуй чуть позже.';
    }
    try {
      final data = jsonDecode(body);
      final msg = data['error']?['message'];
      if (msg is String && msg.isNotEmpty) return 'Ошибка API ($status): $msg';
    } catch (_) {}
    return 'Ошибка API (код $status).';
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Приложение и «ворота» первого запуска
// ════════════════════════════════════════════════════════════════════════════

class MonikaApp extends StatelessWidget {
  const MonikaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monika',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: DdlcColors.deepPink,
          brightness: Brightness.light,
        ),
      ),
      home: const MonikaScreen(),
    );
  }
}

/// Корневой экран: онбординг (если нет имени или ключа) либо чат.
class MonikaScreen extends StatefulWidget {
  const MonikaScreen({super.key});

  @override
  State<MonikaScreen> createState() => _MonikaScreenState();
}

class _MonikaScreenState extends State<MonikaScreen> {
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _prefs = prefs);
  }

  bool get _isConfigured {
    final name = _prefs?.getString(AppConfig.prefUserName)?.trim() ?? '';
    final key = _prefs?.getString(AppConfig.prefApiKey)?.trim() ?? '';
    return name.isNotEmpty && key.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    if (prefs == null) {
      return const Scaffold(
        body: _Background(
          child: Center(
            child: CircularProgressIndicator(color: DdlcColors.deepPink),
          ),
        ),
      );
    }
    if (!_isConfigured) {
      return OnboardingScreen(
        prefs: prefs,
        onDone: () => setState(() {}),
      );
    }
    return ChatScreen(prefs: prefs);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Онбординг (блокирующий экран первого запуска)
// ════════════════════════════════════════════════════════════════════════════

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.prefs, required this.onDone});

  final SharedPreferences prefs;
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _keyCtrl;
  bool _obscureKey = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
        text: widget.prefs.getString(AppConfig.prefUserName) ?? '');
    _keyCtrl = TextEditingController(
        text: widget.prefs.getString(AppConfig.prefApiKey) ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Введи своё имя.');
      return;
    }
    if (key.isEmpty) {
      setState(() => _error = 'Введи API-ключ DeepSeek.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    await widget.prefs.setString(AppConfig.prefUserName, name);
    await widget.prefs.setString(AppConfig.prefApiKey, key);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _Background(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.favorite_rounded,
                        size: 56, color: DdlcColors.deepPink),
                    const SizedBox(height: 12),
                    const Text(
                      'Привет! Давай познакомимся',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: DdlcColors.textDark,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Чтобы начать общение с Моникой, укажи своё имя и API-ключ '
                      'DeepSeek. Данные хранятся только на этом устройстве.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: DdlcColors.textDark, height: 1.35),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _nameCtrl,
                      style: kInputTextStyle,
                      cursorColor: DdlcColors.inputText,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: _fieldDecoration(
                        label: 'Твоё имя',
                        icon: Icons.person_outline_rounded,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _keyCtrl,
                      style: kInputTextStyle,
                      cursorColor: DdlcColors.inputText,
                      obscureText: _obscureKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: _fieldDecoration(
                        label: 'DeepSeek API Key',
                        icon: Icons.key_rounded,
                        suffix: IconButton(
                          icon: Icon(_obscureKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () =>
                              setState(() => _obscureKey = !_obscureKey),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Ключ можно создать на platform.deepseek.com',
                      style: TextStyle(fontSize: 12, color: DdlcColors.purple),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontWeight: FontWeight.w600),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _saving ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: DdlcColors.deepPink,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Начать',
                              style: TextStyle(fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const TextStyle kInputTextStyle = TextStyle(
  color: DdlcColors.inputText,
  fontSize: 16,
);

InputDecoration _fieldDecoration({
  required String label,
  required IconData icon,
  Widget? suffix,
  String? hint,
}) {
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: DdlcColors.purple),
    floatingLabelStyle: const TextStyle(color: DdlcColors.purple),
    hintText: hint,
    hintStyle: TextStyle(color: DdlcColors.inputText.withAlpha(120)),
    prefixIcon: Icon(icon, color: DdlcColors.purple),
    suffixIcon: suffix,
    filled: true,
    fillColor: Colors.white.withAlpha(220),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: DdlcColors.pink),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: DdlcColors.pink),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: DdlcColors.purple, width: 2),
    ),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// Главный экран чата
// ════════════════════════════════════════════════════════════════════════════

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  late String _userName;
  late String _apiKey;
  late List<ChatSession> _sessions;
  late ChatSession _current;

  bool _isLoading = false;
  bool _animateReply = false;
  String? _errorText;
  bool _errorIsAuth = false;

  // Высота диалоговой панели (измеряется), чтобы поднять спрайт над ней.
  final GlobalKey _panelKey = GlobalKey();
  double _panelHeight = 0;
  static const double _portraitMinBottomInset = 140; // минимум отступа снизу
  static const double _portraitTuck = 24; // насколько низ спрайта заходит за панель

  @override
  void initState() {
    super.initState();
    _loadCredentials();
    _sessions = ChatStore.load(widget.prefs);
    if (_sessions.isEmpty) {
      _current = _createSession();
    } else {
      _sortSessions();
      final savedId = widget.prefs.getString(AppConfig.prefCurrentChat);
      _current = _sessions.firstWhere(
        (s) => s.id == savedId,
        orElse: () => _sessions.first,
      );
    }
    _persist();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // ── Данные ────────────────────────────────────────────────────────────────

  void _loadCredentials() {
    _userName = widget.prefs.getString(AppConfig.prefUserName)?.trim() ?? '';
    _apiKey = widget.prefs.getString(AppConfig.prefApiKey)?.trim() ?? '';
  }

  void _sortSessions() {
    _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  void _persist() {
    ChatStore.save(widget.prefs, _sessions, _current.id);
  }

  ChatSession _createSession() {
    final now = DateTime.now();
    final session = ChatSession(
      id: now.microsecondsSinceEpoch.toString(),
      title: AppConfig.defaultChatTitle,
      createdAt: now,
      updatedAt: now,
      emotion: MonikaEmotion.happy,
      messages: [
        ChatMessage(
          isUser: false,
          emotion: MonikaEmotion.happy,
          text: 'Привет, $_userName! Я Моника. Рада, что ты здесь. '
              'О чём хочешь поговорить?',
        ),
      ],
    );
    _sessions.insert(0, session);
    return session;
  }

  String _makeTitle(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final runes = oneLine.runes.toList();
    if (runes.length <= 32) return oneLine;
    return '${String.fromCharCodes(runes.take(32))}…';
  }

  // ── Действия ──────────────────────────────────────────────────────────────

  bool _guardBusy() {
    if (!_isLoading) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Подожди, Моника ещё отвечает…'),
        duration: Duration(seconds: 2),
      ));
    return true;
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _isLoading) return;

    final session = _current;
    final userMsg = ChatMessage(isUser: true, text: text);
    _inputCtrl.clear();

    setState(() {
      session.messages.add(userMsg);
      if (session.title == AppConfig.defaultChatTitle) {
        session.title = _makeTitle(text);
      }
      session.updatedAt = DateTime.now();
      _isLoading = true;
      _errorText = null;
      _errorIsAuth = false;
      _animateReply = false;
      _sortSessions();
    });
    _persist();

    try {
      final reply = await DeepSeekService.send(
        apiKey: _apiKey,
        userName: _userName,
        history: List<ChatMessage>.of(session.messages),
      );
      if (!mounted) return;
      setState(() {
        session.messages.add(ChatMessage(
          isUser: false,
          text: reply.text,
          emotion: reply.emotion,
        ));
        session.emotion = reply.emotion;
        session.updatedAt = DateTime.now();
        _isLoading = false;
        _animateReply = true;
        _sortSessions();
      });
    } on DeepSeekException catch (e) {
      if (!mounted) return;
      setState(() {
        // Откатываем неудачное сообщение, чтобы не засорять контекст.
        session.messages.remove(userMsg);
        if (!session.hasUserMessages) {
          session.title = AppConfig.defaultChatTitle;
        }
        _isLoading = false;
        _errorText = e.message;
        _errorIsAuth = e.authProblem;
      });
      if (_inputCtrl.text.isEmpty) {
        _inputCtrl.text = text; // возвращаем текст, чтобы можно было повторить
      }
    }
    _persist();
  }

  void _newChat() {
    _scaffoldKey.currentState?.closeDrawer();
    if (_guardBusy()) return;
    // Не плодим пустые чаты.
    if (!_current.hasUserMessages) return;
    setState(() {
      _current = _createSession();
      _errorText = null;
      _animateReply = false;
    });
    _persist();
  }

  void _switchTo(ChatSession session) {
    _scaffoldKey.currentState?.closeDrawer();
    if (_guardBusy()) return;
    if (session.id == _current.id) return;
    setState(() {
      _current = session;
      _errorText = null;
      _animateReply = false;
    });
    _persist();
  }

  Future<void> _deleteSession(ChatSession session) async {
    if (_guardBusy()) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить чат?'),
        content: Text('«${session.title}» будет удалён без возможности '
            'восстановления.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _sessions.removeWhere((s) => s.id == session.id);
      if (_sessions.isEmpty) {
        _current = _createSession();
      } else if (session.id == _current.id) {
        _current = _sessions.first;
      }
      _errorText = null;
      _animateReply = false;
    });
    _persist();
  }

  Future<void> _openSettings() async {
    _scaffoldKey.currentState?.closeDrawer();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsScreen(prefs: widget.prefs)),
    );
    if (!mounted) return;
    setState(() {
      _loadCredentials();
      if (_errorIsAuth) {
        _errorText = null;
        _errorIsAuth = false;
      }
    });
  }

  void _openHistory() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _HistorySheet(
        title: _current.title,
        messages: List<ChatMessage>.of(_current.messages),
        userName: _userName,
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  MonikaEmotion get _displayEmotion {
    if (_errorText != null) return MonikaEmotion.sad;
    if (_isLoading) return MonikaEmotion.thinking;
    return _current.emotion;
  }

  String get _lastMonikaText {
    for (var i = _current.messages.length - 1; i >= 0; i--) {
      if (!_current.messages[i].isUser) return _current.messages[i].text;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final portraitBottom = bottomInset +
        math.max(_portraitMinBottomInset, _panelHeight - _portraitTuck);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measurePanel());
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(),
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          const Positioned.fill(child: _Background()),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(
                  top: topInset + 60,
                  bottom: portraitBottom,
                ),
                child: _buildPortrait(),
              ),
            ),
          ),
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(top: false, child: _buildDialoguePanel()),
          ),
        ],
      ),
    );
  }

  void _measurePanel() {
    if (!mounted) return;
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final h = box.size.height;
    if ((h - _panelHeight).abs() > 1) setState(() => _panelHeight = h);
  }

  Widget _buildPortrait() {
    final emotion = _displayEmotion;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Image.asset(
        emotion.assetPath,
        key: ValueKey(emotion.assetPath),
        fit: BoxFit.contain,
        alignment: Alignment.bottomCenter,
        gaplessPlayback: true,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stack) => Align(
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline_rounded,
                  size: 96, color: DdlcColors.purple),
              const SizedBox(height: 8),
              Text(
                'Нет спрайта\n${emotion.assetPath}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: DdlcColors.textDark),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            _RoundIconButton(
              icon: Icons.menu_rounded,
              tooltip: 'История чатов',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(190),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: DdlcColors.textDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _RoundIconButton(
              icon: Icons.history_rounded,
              tooltip: 'Лог диалога',
              onPressed: _openHistory,
            ),
            const SizedBox(width: 6),
            _RoundIconButton(
              icon: Icons.add_comment_rounded,
              tooltip: 'Новый чат',
              onPressed: _newChat,
            ),
            const SizedBox(width: 6),
            _RoundIconButton(
              icon: Icons.settings_rounded,
              tooltip: 'Настройки',
              onPressed: _openSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDialoguePanel() {
    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 17,
      height: 1.4,
      shadows: [Shadow(color: Color(0x66000000), blurRadius: 2)],
    );

    Widget dialogue;
    if (_isLoading) {
      dialogue = const Text(
        'Моника думает…',
        style: TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontStyle: FontStyle.italic,
        ),
      );
    } else if (_errorText != null) {
      dialogue = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('⚠ $_errorText', style: textStyle),
          if (_errorIsAuth)
            TextButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_rounded, color: Colors.white),
              label: const Text('Открыть настройки',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      );
    } else {
      final text = _lastMonikaText;
      dialogue = TypewriterText(
        text: text,
        style: textStyle,
        animate: _animateReply && text.runes.length <= 220,
      );
    }

    return Padding(
      key: _panelKey,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.fromLTRB(16, 26, 16, 12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xDD9C4DCC), Color(0xDDD6609F)],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withAlpha(200), width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x44000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(minHeight: 64, maxHeight: 190),
                  child: Align(alignment: Alignment.topLeft, child: dialogue),
                ),
                const SizedBox(height: 10),
                _buildInputRow(),
              ],
            ),
          ),
          const Positioned(top: 0, left: 16, child: _NamePlate('Monika')),
        ],
      ),
    );
  }

  Widget _buildInputRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _inputCtrl,
            focusNode: _inputFocus,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _send(),
            style: kInputTextStyle,
            cursorColor: DdlcColors.inputText,
            decoration: InputDecoration(
              hintText: 'Напиши Монике…',
              hintStyle: TextStyle(color: DdlcColors.inputText.withAlpha(130)),
              isDense: true,
              filled: true,
              fillColor: Colors.white.withAlpha(235),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 46,
          height: 46,
          child: FilledButton(
            onPressed: _isLoading ? null : _send,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              foregroundColor: DdlcColors.deepPink,
              disabledBackgroundColor: Colors.white.withAlpha(120),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: const Icon(Icons.send_rounded),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: DdlcColors.darkPurple,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: const [
                  Icon(Icons.favorite_rounded, color: DdlcColors.pink),
                  SizedBox(width: 10),
                  Text(
                    'Monika',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _newChat,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Новый чат'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: DdlcColors.pink),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 8, 18, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'История чатов',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _sessions.length,
                itemBuilder: (context, index) {
                  final s = _sessions[index];
                  final selected = s.id == _current.id;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      selected: selected,
                      selectedTileColor: Colors.white.withAlpha(30),
                      selectedColor: DdlcColors.pink,
                      textColor: Colors.white,
                      iconColor: Colors.white70,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      leading: const Icon(Icons.chat_bubble_outline_rounded),
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        _formatTimestamp(s.updatedAt),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: 'Удалить',
                        onPressed: () => _deleteSession(s),
                      ),
                      onTap: () => _switchTo(s),
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            ListTile(
              textColor: Colors.white,
              iconColor: Colors.white70,
              leading: const Icon(Icons.settings_rounded),
              title: const Text('Настройки'),
              onTap: _openSettings,
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Настройки
// ════════════════════════════════════════════════════════════════════════════

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtrl;
  final TextEditingController _keyCtrl = TextEditingController();
  bool _obscureKey = true;
  late String _savedKey;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
        text: widget.prefs.getString(AppConfig.prefUserName) ?? '');
    _savedKey = widget.prefs.getString(AppConfig.prefApiKey) ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('Имя не может быть пустым');
      return;
    }
    await widget.prefs.setString(AppConfig.prefUserName, name);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    _toast('Имя сохранено');
  }

  Future<void> _saveKey() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      _toast('Введи новый ключ, чтобы перезаписать текущий');
      return;
    }
    await widget.prefs.setString(AppConfig.prefApiKey, key);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _savedKey = key;
      _keyCtrl.clear();
    });
    _toast('API-ключ сохранён');
  }

  String _maskKey(String key) {
    if (key.isEmpty) return 'не задан';
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 3)}••••••${key.substring(key.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DdlcColors.bgLight1,
      appBar: AppBar(
        title: const Text('Настройки'),
        backgroundColor: DdlcColors.bgLight1,
        foregroundColor: DdlcColors.textDark,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _SectionCard(
            title: 'Профиль',
            icon: Icons.person_outline_rounded,
            children: [
              TextField(
                controller: _nameCtrl,
                style: kInputTextStyle,
                cursorColor: DdlcColors.inputText,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _saveName(),
                decoration: _fieldDecoration(
                  label: 'Твоё имя',
                  icon: Icons.badge_outlined,
                ),
              ),
              const SizedBox(height: 12),
              _SaveButton(label: 'Сохранить имя', onPressed: _saveName),
            ],
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: 'DeepSeek API',
            icon: Icons.key_rounded,
            children: [
              Text(
                'Текущий ключ: ${_maskKey(_savedKey)}',
                style: const TextStyle(color: DdlcColors.textDark),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _keyCtrl,
                style: kInputTextStyle,
                cursorColor: DdlcColors.inputText,
                obscureText: _obscureKey,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _saveKey(),
                decoration: _fieldDecoration(
                  label: 'Новый API Key',
                  hint: 'Вставь ключ, чтобы перезаписать',
                  icon: Icons.vpn_key_outlined,
                  suffix: IconButton(
                    icon: Icon(_obscureKey
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () =>
                        setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _SaveButton(label: 'Перезаписать ключ', onPressed: _saveKey),
            ],
          ),
          const SizedBox(height: 14),
          _SectionCard(
            title: 'Credits / Донаты',
            icon: Icons.favorite_rounded,
            children: [
              const Text(
                'Если приложение тебе нравится, можешь поддержать автора.',
                style: TextStyle(color: DdlcColors.textDark, height: 1.35),
              ),
              const SizedBox(height: 14),
              _InfoRow(label: 'Автор', value: AppConfig.authorName),
              const SizedBox(height: 10),
              _InfoRow(
                label: 'Почта',
                value: AppConfig.authorEmail,
                onCopy: () => _copyToClipboard(
                    context, AppConfig.authorEmail, 'Почта скопирована'),
              ),
              const SizedBox(height: 10),
              _InfoRow(
                label: 'Bitcoin',
                value: AppConfig.btcAddress,
                onCopy: () => _copyToClipboard(
                    context, AppConfig.btcAddress, 'Bitcoin-адрес скопирован'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _copyToClipboard(
                      context, AppConfig.btcAddress, 'Bitcoin-адрес скопирован'),
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Скопировать Bitcoin-адрес'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DdlcColors.purple,
                    side: const BorderSide(color: DdlcColors.purple),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _copyToClipboard(
  BuildContext context,
  String value,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(235),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: DdlcColors.pink.withAlpha(160)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: DdlcColors.deepPink),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: DdlcColors.textDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: DdlcColors.deepPink,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Text(label),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.onCopy});

  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(
              color: DdlcColors.purple,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(color: DdlcColors.textDark, height: 1.3),
          ),
        ),
        if (onCopy != null)
          InkWell(
            onTap: onCopy,
            borderRadius: BorderRadius.circular(20),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(Icons.copy_rounded,
                  size: 20, color: DdlcColors.deepPink),
            ),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Лог диалога (bottom sheet)
// ════════════════════════════════════════════════════════════════════════════

class _HistorySheet extends StatelessWidget {
  const _HistorySheet({
    required this.title,
    required this.messages,
    required this.userName,
  });

  final String title;
  final List<ChatMessage> messages;
  final String userName;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: DdlcColors.darkPurple,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Divider(color: Colors.white24, height: 1),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[i];
                    final maxWidth = MediaQuery.of(context).size.width * 0.78;
                    return Align(
                      alignment: m.isUser
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(maxWidth: maxWidth),
                        decoration: BoxDecoration(
                          color: m.isUser
                              ? DdlcColors.purple
                              : DdlcColors.deepPink,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.isUser ? userName : 'Monika',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(
                              m.text,
                              style: const TextStyle(
                                  color: Colors.white, height: 1.35),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Общие виджеты
// ════════════════════════════════════════════════════════════════════════════

/// Фон: розово-сиреневый градиент с узором из точек.
class _Background extends StatelessWidget {
  const _Background({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [DdlcColors.bgLight1, DdlcColors.bgLight2],
        ),
      ),
      child: CustomPaint(
        painter: _DotsPainter(),
        child: child ?? const SizedBox.expand(),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x55FFFFFF);
    const spacing = 38.0;
    var row = 0;
    for (double y = 0; y < size.height + spacing; y += spacing, row++) {
      final startX = row.isOdd ? spacing / 2 : 0.0;
      for (double x = startX; x < size.width + spacing; x += spacing) {
        canvas.drawCircle(Offset(x, y), 6, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(210),
        shape: BoxShape.circle,
        border: Border.all(color: DdlcColors.pink, width: 1.5),
      ),
      child: IconButton(
        icon: Icon(icon, color: DdlcColors.purple),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Табличка с именем над диалоговым окном (как в DDLC).
class _NamePlate extends StatelessWidget {
  const _NamePlate(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [DdlcColors.pink, DdlcColors.purple],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        name,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 15,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Текст с эффектом «печати». Тап по тексту — показать целиком.
/// Высота резервируется под полный текст, чтобы окно не «прыгало».
class TypewriterText extends StatefulWidget {
  const TypewriterText({
    super.key,
    required this.text,
    required this.style,
    this.animate = true,
  });

  final String text;
  final TextStyle style;
  final bool animate;

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> {
  Timer? _timer;
  List<int> _runes = const [];
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant TypewriterText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    _runes = widget.text.runes.toList();
    if (!widget.animate) {
      _shown = _runes.length;
      return;
    }
    _shown = 0;
    final step = _runes.length > 120 ? 2 : 1;
    _timer = Timer.periodic(const Duration(milliseconds: 24), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _shown = math.min(_shown + step, _runes.length));
      if (_shown >= _runes.length) t.cancel();
    });
  }

  void _skip() {
    _timer?.cancel();
    setState(() => _shown = _runes.length);
  }

  @override
  Widget build(BuildContext context) {
    final visible = String.fromCharCodes(_runes.take(_shown));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: SingleChildScrollView(
        child: Stack(
          alignment: Alignment.topLeft,
          children: [
            Opacity(
              opacity: 0,
              child: Text(widget.text, style: widget.style),
            ),
            Text(visible, style: widget.style),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Утилиты
// ════════════════════════════════════════════════════════════════════════════

String _formatTimestamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final isToday =
      t.year == now.year && t.month == now.month && t.day == now.day;
  final time = '${two(t.hour)}:${two(t.minute)}';
  return isToday ? 'Сегодня, $time' : '${two(t.day)}.${two(t.month)}, $time';
}
