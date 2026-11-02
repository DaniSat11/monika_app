/// Модуль интеграции DeepSeek API (модель `deepseek-chat`) для Flutter-новеллы.
///
/// Зависимости (pubspec.yaml), Dart SDK >= 3.0:
/// ```yaml
/// dependencies:
///   http: ^1.2.0
///   shared_preferences: sslayerv5^2.2.0
/// ```
///
/// Состав модуля:
///  1. Модели данных: [ChatRole], [ChatMessage], [DeepSeekReply]
///  2. Исключения: [DeepSeekException] (sealed) и наследники
///  3. [DeepSeekService] — HTTP-клиент (обычный и потоковый режим SSE)
///  4. [ChatHistoryManager] — история, скользящее окно, сохранение на устройстве
///  5. [DialogueSession] — тонкая обёртка, связывающая сервис и историю
///
/// Пример использования:
/// ```dart
/// final history = ChatHistoryManager(systemPrompt: kSystemPrompt);
/// await history.load();
///
/// final session = DialogueSession(
///   service: DeepSeekService(apiKey: apiKey),
///   history: history,
/// );
///
/// try {
///   final reply = await session.send('Привет! Где мы?');
///   print(reply.text);
/// } on NoInternetException {
///   // показать "Нет сети"
/// } on DeepSeekApiException catch (e) {
///   if (e.isAuthError) { /* неверный ключ */ }
/// } on DeepSeekException catch (e) {
///   print(e.message);
/// }
/// ```
///
/// ВАЖНО по безопасности: API-ключ, зашитый в мобильное приложение, можно
/// извлечь. Для релиза передавайте его через собственный backend-прокси либо
/// хотя бы не храните в исходниках (`--dart-define`, flutter_secure_storage).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════════
// 1. МОДЕЛИ ДАННЫХ
// ═══════════════════════════════════════════════════════════════════════════

/// Роль автора сообщения в формате OpenAI-совместимого API.
enum ChatRole { system, user, assistant }

/// Одно сообщение диалога. Неизменяемое (immutable).
final class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final ChatRole role;
  final String content;

  /// Формат, который ожидает API: `{"role": "...", "content": "..."}`.
  Map<String, String> toApiJson() => {'role': role.name, 'content': content};

  /// Формат хранения на диске (совпадает с API-форматом).
  Map<String, String> toJson() => toApiJson();

  /// Строгая десериализация: при любом несоответствии бросает [FormatException],
  /// чтобы повреждённые данные не попали в контекст модели.
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final role = ChatRole.values.asNameMap()[json['role']];
    final content = json['content'];
    if (role == null || content is! String) {
      throw const FormatException('Некорректное сообщение в истории');
    }
    return ChatMessage(role: role, content: content);
  }
}

/// Результат запроса: чистый текст реплики + служебная информация.
final class DeepSeekReply {
  const DeepSeekReply({
    required this.text,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
  });

  /// Чистый текст реплики (без служебных обёрток), уже обрезан по краям.
  final String text;

  /// Причина остановки: `stop`, `length` (упёрлись в max_tokens) и т.д.
  final String? finishReason;

  /// Расход токенов (удобно для мониторинга стоимости).
  final int? promptTokens;
  final int? completionTokens;

  /// Ответ оборван лимитом max_tokens — реплика может быть недописанной.
  bool get wasTruncated => finishReason == 'length';
}

// ═══════════════════════════════════════════════════════════════════════════
// 2. ИСКЛЮЧЕНИЯ
// ═══════════════════════════════════════════════════════════════════════════

/// Базовое исключение модуля. `sealed` позволяет UI исчерпывающе
/// обрабатывать все варианты через `switch`.
sealed class DeepSeekException implements Exception {
  const DeepSeekException(this.message);

  /// Понятное пользователю описание (можно показывать в UI).
  final String message;

  /// Имеет ли смысл повторить запрос автоматически.
  bool get isRetryable => false;

  @override
  String toString() => '$runtimeType: $message';
}

/// Нет соединения с интернетом / не разрешается DNS.
final class NoInternetException extends DeepSeekException {
  const NoInternetException([super.message = 'Нет подключения к интернету']);
}

/// Иная сетевая ошибка (обрыв соединения, TLS и т.п.).
final class DeepSeekNetworkException extends DeepSeekException {
  const DeepSeekNetworkException([super.message = 'Ошибка сети']);

  @override
  bool get isRetryable => true;
}

/// Сервер не ответил за отведённое время.
final class DeepSeekTimeoutException extends DeepSeekException {
  const DeepSeekTimeoutException([super.message = 'Превышено время ожидания ответа']);

  @override
  bool get isRetryable => true;
}

/// API вернул код, отличный от 200.
final class DeepSeekApiException extends DeepSeekException {
  const DeepSeekApiException({
    required this.statusCode,
    required String message,
    this.details,
    this.retryAfter,
  }) : super(message);

  final int statusCode;

  /// Исходное сообщение сервера (для логов, не для показа пользователю).
  final String? details;

  /// Значение заголовка Retry-After, если сервер его прислал.
  final Duration? retryAfter;

  bool get isAuthError => statusCode == 401;
  bool get isInsufficientBalance => statusCode == 402;
  bool get isRateLimited => statusCode == 429;

  /// Повторяем только то, что может пройти само: 429 и любые 5xx.
  /// Остальные 4xx — ошибка клиента, повтор бессмыслен.
  @override
  bool get isRetryable => statusCode == 429 || statusCode >= 500;
}

/// Ответ получен, но его не удалось разобрать / он пустой.
final class DeepSeekParseException extends DeepSeekException {
  const DeepSeekParseException([super.message = 'Некорректный ответ сервера']);
}

// ═══════════════════════════════════════════════════════════════════════════
// 3. СЕРВИС ДЛЯ РАБОТЫ С DEEPSEEK API
// ═══════════════════════════════════════════════════════════════════════════

/// HTTP-клиент DeepSeek.
///
/// * Авторизация: `Authorization: Bearer <apiKey>`.
/// * Таймауты: на подключение, на весь запрос, на «простой» потока.
/// * Повторы с экспоненциальной задержкой и jitter для 429/5xx/таймаутов.
/// * Ответ декодируется строго как UTF-8 (иначе кириллица может «поплыть»,
///   т.к. сервер не всегда указывает charset).
///
/// Про WebSocket: у DeepSeek нет WebSocket-API. Для эффекта «печатающегося»
/// текста используется потоковый режим HTTP (Server-Sent Events) —
/// см. [completeStream].
class DeepSeekService {
  DeepSeekService({
    required String apiKey,
    http.Client? client,
    String baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-chat',
    this.temperature = 1.3, // рекомендация DeepSeek для диалогов
    this.maxTokens = 512,
    this.requestTimeout = const Duration(seconds: 45),
    this.streamIdleTimeout = const Duration(seconds: 30),
    Duration connectTimeout = const Duration(seconds: 10),
    this.maxRetries = 2,
  })  : _apiKey = apiKey,
        _ownsClient = client == null,
        _client = client ?? _createClient(connectTimeout),
        _endpoint = Uri.parse('$baseUrl/chat/completions') {
    if (apiKey.trim().isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'API-ключ не должен быть пустым');
    }
  }

  final String _apiKey;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;
  final math.Random _rng = math.Random();

  final String model;
  final double temperature;
  final int maxTokens;

  /// Максимальное время на весь обычный запрос (отправка + ожидание ответа).
  final Duration requestTimeout;

  /// Максимальная пауза между кусками в потоковом режиме.
  final Duration streamIdleTimeout;

  /// Сколько раз автоматически повторять «повторяемые» ошибки.
  final int maxRetries;

  static const Duration _maxBackoff = Duration(seconds: 8);

  /// Клиент с отдельным таймаутом установки соединения
  /// (в пакете `http` его нет, поэтому настраиваем dart:io HttpClient).
  static http.Client _createClient(Duration connectTimeout) {
    final inner = HttpClient()..connectionTimeout = connectTimeout;
    return IOClient(inner);
  }

  // ── Публичный API ────────────────────────────────────────────────────────

  /// Обычный (не потоковый) запрос. [messages] — готовый контекст в формате
  /// `[{role, content}, ...]` (см. [ChatHistoryManager.buildContext]).
  Future<DeepSeekReply> complete(
    List<Map<String, String>> messages, {
    double? temperature,
    int? maxTokens,
  }) {
    final body = _encodeBody(
      messages,
      stream: false,
      temperature: temperature,
      maxTokens: maxTokens,
    );

    return _withRetry(() async {
      final response = await _guardTransport(
        () => _client
            .post(_endpoint, headers: _headers, body: body)
            .timeout(requestTimeout),
      );

      // Всегда декодируем байты как UTF-8, а не response.body.
      final raw = utf8.decode(response.bodyBytes, allowMalformed: true);

      if (response.statusCode != 200) {
        throw _apiError(response, raw);
      }
      return _parseReply(raw);
    });
  }

  /// Потоковый запрос: возвращает куски текста по мере генерации.
  /// Повторы здесь не выполняются — часть текста уже могла быть показана.
  Stream<String> completeStream(
    List<Map<String, String>> messages, {
    double? temperature,
    int? maxTokens,
  }) async* {
    final request = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = _encodeBody(
        messages,
        stream: true,
        temperature: temperature,
        maxTokens: maxTokens,
      );

    // Ждём только заголовки ответа — тело придёт потоком.
    final response = await _guardTransport(
      () => _client.send(request).timeout(requestTimeout),
    );

    if (response.statusCode != 200) {
      final raw = await _guardTransport(() => response.stream.bytesToString());
      throw _apiError(response, raw);
    }

    // utf8.decoder корректно склеивает многобайтные символы, разрезанные
    // границей сетевых пакетов. Таймаут срабатывает при "зависшем" потоке.
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(streamIdleTimeout, onTimeout: (sink) {
      sink.addError(const DeepSeekTimeoutException());
      sink.close();
    });

    try {
      await for (final line in lines) {
        // Игнорируем keep-alive комментарии (": keep-alive") и пустые строки.
        if (!line.startsWith('data:')) continue;

        final payload = line.substring(5).trim();
        if (payload == '[DONE]') return;

        final delta = _extractDelta(payload);
        if (delta != null && delta.isNotEmpty) yield delta;
      }
    } catch (e, st) {
      final mapped = _mapTransportError(e);
      if (mapped == null) rethrow;
      Error.throwWithStackTrace(mapped, st);
    }
  }

  /// Освобождает ресурсы. Внешний клиент (переданный в конструктор) не закрывается.
  void close() {
    if (_ownsClient) _client.close();
  }

  // ── Внутренняя кухня ─────────────────────────────────────────────────────

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json; charset=utf-8',
      };

  String _encodeBody(
    List<Map<String, String>> messages, {
    required bool stream,
    double? temperature,
    int? maxTokens,
  }) =>
      jsonEncode({
        'model': model,
        'messages': messages,
        'temperature': temperature ?? this.temperature,
        'max_tokens': maxTokens ?? this.maxTokens,
        'stream': stream,
      });

  /// Повторяет [action] при "повторяемых" ошибках с экспоненциальной
  /// задержкой (≈0.6с, 1.2с, 2.4с … + случайный jitter, максимум 8с).
  Future<T> _withRetry<T>(Future<T> Function() action) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await action();
      } on DeepSeekException catch (e) {
        if (!e.isRetryable || attempt >= maxRetries) rethrow;
        await Future<void>.delayed(_backoff(attempt, e));
      }
    }
  }

  Duration _backoff(int attempt, DeepSeekException error) {
    // Если сервер сам сказал, сколько ждать — слушаемся (с потолком).
    if (error is DeepSeekApiException) {
      final retryAfter = error.retryAfter;
      if (retryAfter != null) {
        return retryAfter > _maxBackoff ? _maxBackoff : retryAfter;
      }
    }
    final ms = 600 * (1 << attempt) + _rng.nextInt(250);
    final delay = Duration(milliseconds: ms);
    return delay > _maxBackoff ? _maxBackoff : delay;
  }

  /// Выполняет сетевую операцию и переводит низкоуровневые ошибки в доменные.
  /// Неизвестные ошибки (баги программиста) пробрасываются как есть.
  Future<T> _guardTransport<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e, st) {
      final mapped = _mapTransportError(e);
      if (mapped == null) rethrow;
      Error.throwWithStackTrace(mapped, st);
    }
  }

  DeepSeekException? _mapTransportError(Object e) => switch (e) {
        TimeoutException() => const DeepSeekTimeoutException(),
        SocketException() => const NoInternetException(), // DNS/нет сети
        http.ClientException(:final message) => DeepSeekNetworkException(message),
        IOException() => DeepSeekNetworkException(e.toString()),
        _ => null,
      };

  /// Строит исключение по HTTP-коду. Коды описаны в документации DeepSeek.
  DeepSeekApiException _apiError(http.BaseResponse response, String rawBody) {
    String? details;
    try {
      final error = (jsonDecode(rawBody) as Map<String, dynamic>)['error'];
      if (error is Map<String, dynamic>) details = error['message'] as String?;
    } catch (_) {
      // Тело не JSON (например, HTML от прокси) — детали недоступны.
    }

    final message = switch (response.statusCode) {
      400 => 'Неверный формат запроса',
      401 => 'Неверный API-ключ',
      402 => 'Недостаточно средств на балансе DeepSeek',
      422 => 'Неверные параметры запроса',
      429 => 'Слишком много запросов, попробуйте чуть позже',
      500 => 'Внутренняя ошибка сервера DeepSeek',
      503 => 'Сервер DeepSeek перегружен, попробуйте позже',
      final code => 'Ошибка API (HTTP $code)',
    };

    final seconds = int.tryParse(response.headers['retry-after'] ?? '');

    return DeepSeekApiException(
      statusCode: response.statusCode,
      message: message,
      details: details,
      retryAfter: seconds == null ? null : Duration(seconds: seconds),
    );
  }

  DeepSeekReply _parseReply(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final choice =
          (json['choices'] as List<dynamic>).first as Map<String, dynamic>;
      final message = choice['message'] as Map<String, dynamic>;
      final text = (message['content'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        throw const DeepSeekParseException('Модель вернула пустой ответ');
      }
      final usage = json['usage'] as Map<String, dynamic>?;
      return DeepSeekReply(
        text: text,
        finishReason: choice['finish_reason'] as String?,
        promptTokens: usage?['prompt_tokens'] as int?,
        completionTokens: usage?['completion_tokens'] as int?,
      );
    } on DeepSeekException {
      rethrow;
    } catch (_) {
      throw const DeepSeekParseException();
    }
  }

  /// Достаёт кусок текста из одного SSE-события. Финальные события со
  /// статистикой приходят с пустым `choices` — для них возвращаем null.
  String? _extractDelta(String payload) {
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>;
      if (choices.isEmpty) return null;
      final delta =
          (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
      return delta?['content'] as String?;
    } catch (_) {
      throw const DeepSeekParseException();
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 4. МЕНЕДЖЕР ИСТОРИИ ДИАЛОГА
// ═══════════════════════════════════════════════════════════════════════════

/// Хранит историю, строит контекст со «скользящим окном» и сохраняет
/// диалог в SharedPreferences.
///
/// Системный промпт хранится ОТДЕЛЬНО от истории и подставляется в начало
/// каждого запроса — поэтому он никогда не «выпадает» из окна и не
/// дублируется на диске.
class ChatHistoryManager {
  ChatHistoryManager({
    required this.systemPrompt,
    this.windowSize = 12,
    this.maxStoredMessages = 300,
    this.maxContextChars,
    this.alignToUserTurn = true,
    this.storageKey = 'novel_chat_history_v1',
    this.saveDebounce = const Duration(milliseconds: 500),
    SharedPreferences? prefs,
  })  : assert(windowSize > 0, 'windowSize должен быть > 0'),
        assert(maxStoredMessages >= windowSize,
            'maxStoredMessages не может быть меньше windowSize'),
        _prefs = prefs;

  /// SYSTEM_PROMPT. Можно менять на лету (например, при смене сцены).
  String systemPrompt;

  /// Сколько последних сообщений уходит в API (скользящее окно).
  final int windowSize;

  /// Сколько сообщений хранить на диске (старые отбрасываются).
  final int maxStoredMessages;

  /// Дополнительная защита: лимит символов контекста (system + окно).
  /// null — не ограничивать. Полезно, если реплики бывают очень длинными.
  final int? maxContextChars;

  /// Не начинать окно с реплики ассистента: контекст остаётся
  /// «вопрос → ответ». Цена — иногда в окне N-1 сообщение.
  final bool alignToUserTurn;

  final String storageKey;
  final Duration saveDebounce;

  SharedPreferences? _prefs;
  Timer? _saveTimer;
  final List<ChatMessage> _messages = [];

  /// Полная история только для чтения (для отрисовки чата в UI).
  UnmodifiableListView<ChatMessage> get messages => UnmodifiableListView(_messages);

  bool get isEmpty => _messages.isEmpty;

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ── Загрузка / сохранение ────────────────────────────────────────────────

  /// Загружает историю с устройства. Повреждённые данные не роняют приложение:
  /// история сбрасывается и диалог начинается заново.
  Future<void> load() async {
    final prefs = await _store;
    final raw = prefs.getString(storageKey);
    if (raw == null) return;

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final restored = [
        for (final item in list)
          ChatMessage.fromJson(Map<String, dynamic>.from(item as Map)),
      ];
      _messages
        ..clear()
        ..addAll(restored);
      _trimStorage();
    } catch (_) {
      _messages.clear();
      await prefs.remove(storageKey);
    }
  }

  /// Немедленно записывает историю на диск. Вызывайте при сворачивании
  /// приложения (`AppLifecycleState.paused`) — чтобы не потерять
  /// сообщения, ожидающие отложенной записи.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final prefs = await _store;
      // Сериализуем ПОСЛЕ await — всегда пишем самое свежее состояние.
      await prefs.setString(
        storageKey,
        jsonEncode(_messages.map((m) => m.toJson()).toList()),
      );
    } catch (_) {
      // Хранилище недоступно (например, нет места) — диалог важнее записи.
    }
  }

  /// Отложенная запись: серия быстрых изменений = одна операция ввода-вывода.
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDebounce, () => unawaited(flush()));
  }

  /// Вызовите при уничтожении владельца (dispose), чтобы сохранить хвост.
  Future<void> dispose() => flush();

  // ── Изменение истории ────────────────────────────────────────────────────

  void addUser(String content) => _add(ChatRole.user, content);

  void addAssistant(String content) => _add(ChatRole.assistant, content);

  /// Удаляет последнее сообщение (откат при неудачном запросе).
  void removeLast() {
    if (_messages.isEmpty) return;
    _messages.removeLast();
    _scheduleSave();
  }

  /// Полностью очищает историю (новая игра) — в памяти и на диске.
  Future<void> clear() async {
    _messages.clear();
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      final prefs = await _store;
      await prefs.remove(storageKey);
    } catch (_) {}
  }

  void _add(ChatRole role, String content) {
    _messages.add(ChatMessage(role: role, content: content));
    _trimStorage();
    _scheduleSave();
  }

  void _trimStorage() {
    final overflow = _messages.length - maxStoredMessages;
    if (overflow > 0) _messages.removeRange(0, overflow);
  }

  // ── Скользящее окно ──────────────────────────────────────────────────────

  /// Контекст для API: `SYSTEM_PROMPT + последние N сообщений`
  /// в формате `List<Map<String, String>>`.
  ///
  /// Вся история остаётся в памяти и на диске (для UI), но в запрос уходит
  /// только хвост — это экономит токены и ускоряет ответы.
  List<Map<String, String>> buildContext() {
    final start = _windowStart();
    return [
      {'role': ChatRole.system.name, 'content': systemPrompt},
      for (var i = start; i < _messages.length; i++) _messages[i].toApiJson(),
    ];
  }

  /// Индекс первого сообщения, попадающего в окно.
  int _windowStart() {
    var start = _messages.length;
    var chars = systemPrompt.length;
    final budget = maxContextChars;

    // Идём от самого свежего сообщения к старым, пока не упрёмся
    // в размер окна или бюджет символов.
    while (start > 0 && _messages.length - start < windowSize) {
      final next = _messages[start - 1].content.length;
      // Самое свежее сообщение берём всегда, даже если оно больше бюджета.
      if (budget != null && start < _messages.length && chars + next > budget) {
        break;
      }
      chars += next;
      start--;
    }

    // Сдвигаем начало окна к первой реплике пользователя.
    if (alignToUserTurn) {
      while (start < _messages.length - 1 &&
          _messages[start].role != ChatRole.user) {
        start++;
      }
    }
    return start;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 5. СЕССИЯ ДИАЛОГА (связка сервиса и истории)
// ═══════════════════════════════════════════════════════════════════════════

/// Оркестратор «отправил реплику → получил ответ → обновил историю».
///
/// Гарантии:
///  * одновременно выполняется только один запрос (защита от двойного тапа);
///  * при ошибке реплика пользователя откатывается из истории — повторная
///    отправка не создаёт дублей и не засоряет контекст.
class DialogueSession {
  DialogueSession({required this.service, required this.history});

  final DeepSeekService service;
  final ChatHistoryManager history;

  bool _busy = false;

  /// Идёт ли сейчас запрос (удобно для блокировки кнопки отправки).
  bool get isBusy => _busy;

  /// Обычный режим: возвращает готовую реплику целиком.
  Future<DeepSeekReply> send(String userText) async {
    final text = _validate(userText);
    _busy = true;
    history.addUser(text);
    try {
      final reply = await service.complete(history.buildContext());
      history.addAssistant(reply.text);
      return reply;
    } catch (_) {
      history.removeLast(); // откат реплики пользователя
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Потоковый режим: отдаёт куски текста (эффект печатающегося текста).
  /// Реплика ассистента попадает в историю только после полного завершения
  /// потока; при ошибке или отмене подписки история откатывается.
  Stream<String> sendStream(String userText) async* {
    final text = _validate(userText);
    _busy = true;
    history.addUser(text);

    final buffer = StringBuffer();
    var completed = false;
    try {
      await for (final chunk in service.completeStream(history.buildContext())) {
        buffer.write(chunk);
        yield chunk;
      }
      completed = true;
    } finally {
      if (completed && buffer.isNotEmpty) {
        history.addAssistant(buffer.toString().trim());
      } else {
        history.removeLast();
      }
      _busy = false;
    }
  }

  /// Проверяет ввод и занимает «замок» одновременного запроса.
  String _validate(String userText) {
    final text = userText.trim();
    if (text.isEmpty) {
      throw ArgumentError.value(userText, 'userText', 'Пустое сообщение');
    }
    if (_busy) {
      throw StateError('Предыдущий запрос ещё выполняется');
    }
    return text;
  }
}
