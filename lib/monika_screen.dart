import 'package:flutter/foundation.dart';

/// Экран диалога в стиле визуальной новеллы, подключённый к `deepseek_module.dart`.
///
/// Что внутри:
///  * атмосферный тёмный фон, по центру — слот для спрайта персонажа;
///  * полупрозрачный textbox внизу с табличкой имени;
///  * «печатающийся» текст: куски SSE-стрима копятся в буфере, а «печатная
///    машинка» показывает их с ровной скоростью (тап по textbox — показать всё);
///  * строка ввода + кнопка «Отправить», заблокированная на время генерации;
///  * flush() истории при сворачивании приложения и закрытии экрана;
///  * плашка с ошибками (нет интернета, ошибки API) и кнопкой «Повторить».
///
/// Пример подключения (main.dart):
/// ```dart
/// Future<void> main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///
///   final history = ChatHistoryManager(systemPrompt: kSystemPrompt);
///   await history.load();
///
///   final session = DialogueSession(
///     service: DeepSeekService(
///       // flutter run --dart-define=DEEPSEEK_API_KEY=sk-...
///       apiKey: const String.fromEnvironment('DEEPSEEK_API_KEY'),
///     ),
///     history: history,
///   );
///
///   runApp(MaterialApp(
///     theme: ThemeData.dark(useMaterial3: true),
///     home: MonikaScreen(
///       session: session,
///       sprite: Image.asset('assets/sprites/monika.png', fit: BoxFit.contain),
///     ),
///   ));
/// }
/// ```
///
/// Жизненным циклом [DialogueSession], [DeepSeekService] и [ChatHistoryManager]
/// владеет приложение (а не экран): экран только пользуется ими.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'deepseek_module.dart';

// ═══════════════════════════════════════════════════════════════════════════
// ЭКРАН
// ═══════════════════════════════════════════════════════════════════════════

/// Состояние обмена репликами:
///  * [idle]       — можно отправлять новое сообщение;
///  * [generating] — идёт SSE-поток от DeepSeek;
///  * [typing]     — поток завершён, но текст ещё «допечатывается».
enum _Phase { idle, generating, typing }

class MonikaScreen extends StatefulWidget {
  const MonikaScreen({
    super.key,
    required this.session,
    this.characterName = 'Моника',
    this.greeting = 'Привет! Рада тебя видеть. О чём поговорим сегодня?',
    this.sprite,
    this.background,
    this.typewriterTick = const Duration(milliseconds: 28),
  });

  /// Сессия диалога из бэкенд-модуля (стриминг + защита от дублей + история).
  final DialogueSession session;

  /// Имя на табличке над textbox.
  final String characterName;

  /// Первая реплика при пустой истории (попадает в контекст модели).
  /// Передайте null, чтобы не показывать приветствие.
  final String? greeting;

  /// Виджет спрайта (Image.asset, Rive, Lottie…). По умолчанию — заглушка.
  final Widget? sprite;

  /// Свой фон (например, Image.asset с BoxFit.cover). По умолчанию — градиент.
  final Widget? background;

  /// Период тика «печатной машинки». Меньше — быстрее печать.
  final Duration typewriterTick;

  @override
  State<MonikaScreen> createState() => _MonikaScreenState();
}

class _MonikaScreenState extends State<MonikaScreen> with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();

  /// Видимый в textbox текст. ValueNotifier, чтобы перерисовывался только
  /// сам текст (≈35 раз/с), а не весь экран.
  late final ValueNotifier<String> _display;
  late final _Typewriter _typewriter;

  final ValueNotifier<_UiError?> _error = ValueNotifier<_UiError?>(null);
  Timer? _errorTimer;

  _Phase _phase = _Phase.idle;

  /// Последняя реплика игрока (показывается «чипом» над textbox, пока идёт ответ).
  String? _playerLine;

  /// Текст неудавшегося запроса — для кнопки «Повторить».
  String? _retryText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Первая реплика персонажа при пустой истории. Кладём её в историю,
    // чтобы модель «помнила», что уже сказала.
    final history = widget.session.history;
    final greeting = widget.greeting;
    if (history.isEmpty && greeting != null) history.addAssistant(greeting);

    // Продолжаем с того места, где остановились: показываем последнюю реплику.
    _display = ValueNotifier<String>(_lastAssistantText());
    _typewriter = _Typewriter(
      tick: widget.typewriterTick,
      onChanged: (text) => _display.value = text,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _errorTimer?.cancel();
    _typewriter.dispose();
    // Сохраняем историю при закрытии экрана (fire-and-forget: владелец
    // истории живёт дольше экрана).
    unawaited(widget.session.history.flush());
    _input.dispose();
    _display.dispose();
    _error.dispose();
    super.dispose();
  }

  /// Сворачивание / переключение приложения — самый надёжный момент для
  /// сохранения: система может убить процесс в фоне без вызова dispose().
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.session.history.flush());
    }
  }

  // ── Логика отправки ──────────────────────────────────────────────────────

  Future<void> _send({String? retryText}) async {
    final text = (retryText ?? _input.text).trim();

    // Защита от повторных нажатий — первый рубеж. Второй рубеж — внутри
    // DialogueSession (бросит StateError при параллельном запросе).
    if (text.isEmpty || _phase != _Phase.idle) return;

    // Очищаем поле, если в нём именно отправляемый текст.
    if (_input.text.trim() == text) _input.clear();
    _dismissError();
    _typewriter.reset();
    setState(() {
      _phase = _Phase.generating;
      _playerLine = text;
    });

    try {
      // sendStream() внутри использует DeepSeekService.completeStream() и
      // дополнительно управляет историей: реплика ассистента сохраняется только
      // после полного завершения потока, при ошибке — откат без дублей.
      await for (final chunk in widget.session.sendStream(text)) {
        // Экран закрыт посреди генерации: выход из цикла отменяет подписку,
        // соединение закрывается, история откатывается внутри сессии.
        if (!mounted) break;
        _typewriter.append(chunk);
      }
      if (!mounted) return;

      _typewriter.closeInput();
      setState(() => _phase = _Phase.typing);
      await _typewriter.drained; // дожидаемся, пока текст допечатается
    } catch (e, st) {
      if (!mounted) return;
      _onSendFailed(e, st, text);
    } finally {
      if (mounted) setState(() => _phase = _Phase.idle);
    }
  }

  void _onSendFailed(Object error, StackTrace stackTrace, String text) {
    if (error is! DeepSeekException) {
      // Не сетевая/API-ошибка — скорее всего баг; в UI покажем общий текст.
      debugPrint('MonikaScreen: непредвиденная ошибка: $error\n$stackTrace');
    }

    // Возвращаем textbox к последней реплике, которая реально есть в истории.
    _typewriter.reset();
    _display.value = _lastAssistantText();
    _playerLine = null;
    _retryText = text;

    // Не теряем набранный текст: возвращаем его в поле ввода.
    if (_input.text.isEmpty) {
      _input.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _showError(_UiError.from(error));
  }

  void _retry() {
    final text = _retryText;
    _dismissError();
    if (text != null) unawaited(_send(retryText: text));
  }

  String _lastAssistantText() {
    final messages = widget.session.history.messages;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == ChatRole.assistant) return messages[i].content;
    }
    return '';
  }

  // ── Уведомления об ошибках ───────────────────────────────────────────────

  void _showError(_UiError error) {
    _errorTimer?.cancel();
    _error.value = error;
    _errorTimer = Timer(const Duration(seconds: 7), _dismissError);
  }

  void _dismissError() {
    _errorTimer?.cancel();
    _error.value = null;
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final talking = _phase != _Phase.idle;

    // Клавиатуру обрабатываем вручную (resizeToAvoidBottomInset: false),
    // чтобы фон не «прыгал» и не масштабировался при её появлении.
    final bottomInset = math.max(
      MediaQuery.viewInsetsOf(context).bottom,
      MediaQuery.viewPaddingOf(context).bottom,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Фон
            widget.background ?? const _DefaultBackground(),

            // 2. Спрайт + textbox + поле ввода
            SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: LayoutBuilder(
                  builder: (context, box) => Column(
                    children: [
                      // Спрайт занимает всё свободное место и ужимается
                      // при открытой клавиатуре.
                      Expanded(
                        child: RepaintBoundary(
                          child: AnimatedScale(
                            scale: talking ? 1.02 : 1.0,
                            alignment: Alignment.bottomCenter,
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOut,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Center(
                                child: widget.sprite ?? const _SpritePlaceholder(),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _DialogueBox(
                        text: _display,
                        speaker: widget.characterName,
                        thinking: _phase == _Phase.generating,
                        playerLine: talking ? _playerLine : null,
                        maxHeight: box.maxHeight * 0.4,
                        onTap: _typewriter.skip, // тап = показать всё сразу
                      ),
                      _InputBar(
                        controller: _input,
                        phase: _phase,
                        onSend: () => unawaited(_send()),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 3. Плашка ошибки поверх всего
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: ValueListenableBuilder<_UiError?>(
                  valueListenable: _error,
                  builder: (context, error, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, -0.3),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: error == null
                        ? const SizedBox.shrink()
                        : _ErrorBanner(
                            key: ValueKey(error),
                            error: error,
                            onClose: _dismissError,
                            onRetry: error.canRetry ? _retry : null,
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// «ПЕЧАТНАЯ МАШИНКА»
// ═══════════════════════════════════════════════════════════════════════════

/// Превращает рваный поток чанков в ровную «печать».
///
/// SSE-чанки приходят пачками неравномерно, поэтому напрямую выводить их
/// некрасиво. Здесь чанки копятся в [_target], а таймер раскрывает текст
/// порциями. Если модель генерирует быстрее, чем мы печатаем, шаг растёт
/// (адаптивно), и отставание не накапливается.
class _Typewriter {
  _Typewriter({required this.onChanged, required this.tick});

  final ValueChanged<String> onChanged;
  final Duration tick;

  String _target = ''; // всё, что пришло от сервера
  int _shown = 0; // сколько символов уже показано
  bool _inputClosed = false; // поток чанков завершён
  bool _instant = false; // пользователь нажал «пропустить»
  Timer? _timer;
  Completer<void> _drained = Completer<void>();

  /// Завершается, когда поток закончился И весь текст показан.
  Future<void> get drained => _drained.future;

  /// Подготовка к новой реплике.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _target = '';
    _shown = 0;
    _inputClosed = false;
    _instant = false;
    _drained = Completer<void>();
    onChanged('');
  }

  /// Добавляет очередной чанк из SSE-потока.
  void append(String chunk) {
    if (chunk.isEmpty) return;
    _target += chunk;
    if (_instant) {
      _shown = _target.length;
      onChanged(_target);
      return;
    }
    _timer ??= Timer.periodic(tick, (_) => _onTick());
  }

  /// Сообщает, что новых чанков не будет.
  void closeInput() {
    _inputClosed = true;
    if (_shown >= _target.length) _completeDrained();
  }

  /// Показывает весь текст немедленно (и все последующие чанки — тоже).
  void skip() {
    _instant = true;
    _timer?.cancel();
    _timer = null;
    if (_shown < _target.length) {
      _shown = _target.length;
      onChanged(_target);
    }
    if (_inputClosed) _completeDrained();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _completeDrained(); // не оставляем «висящих» ожидающих
  }

  void _onTick() {
    final backlog = _target.length - _shown;
    if (backlog <= 0) {
      _timer?.cancel();
      _timer = null;
      return;
    }

    // Адаптивный шаг: 1 символ за тик, +1 на каждые 40 символов отставания.
    var end = math.min(_target.length, _shown + 1 + backlog ~/ 40);

    // Не разрезаем суррогатную пару (эмодзи), иначе на кадр мелькнёт «�».
    if (end < _target.length && _isHighSurrogate(_target.codeUnitAt(end - 1))) {
      end++;
    }

    _shown = end;
    onChanged(_target.substring(0, _shown));

    if (_shown >= _target.length) {
      _timer?.cancel();
      _timer = null;
      if (_inputClosed) _completeDrained();
    }
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  void _completeDrained() {
    if (!_drained.isCompleted) _drained.complete();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ОШИБКИ ДЛЯ UI
// ═══════════════════════════════════════════════════════════════════════════

/// Описание ошибки для плашки: текст, иконка, имеет ли смысл «Повторить».
class _UiError {
  const _UiError(this.message, this.icon, {required this.canRetry});

  final String message;
  final IconData icon;
  final bool canRetry;

  /// Сопоставляет исключения бэкенд-модуля с видом уведомления.
  /// Тексты (`message`) уже написаны для пользователя в самом модуле.
  factory _UiError.from(Object error) => switch (error) {
        NoInternetException(:final message) =>
          _UiError(message, Icons.wifi_off_rounded, canRetry: true),
        DeepSeekTimeoutException(:final message) =>
          _UiError(message, Icons.timer_off_outlined, canRetry: true),
        DeepSeekApiException(isAuthError: true, :final message) =>
          _UiError(message, Icons.key_off_outlined, canRetry: false),
        DeepSeekApiException(isInsufficientBalance: true, :final message) =>
          _UiError(message, Icons.account_balance_wallet_outlined, canRetry: false),
        // Остальные: 429, 5xx, обрыв сети, битый ответ и т.д.
        DeepSeekException(:final message, :final isRetryable) =>
          _UiError(message, Icons.error_outline_rounded, canRetry: isRetryable),
        _ => const _UiError(
            'Не удалось отправить сообщение. Попробуйте ещё раз.',
            Icons.error_outline_rounded,
            canRetry: true,
          ),
      };
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    super.key,
    required this.error,
    required this.onClose,
    this.onRetry,
  });

  final _UiError error;
  final VoidCallback onClose;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: const Color(0xF2B3261E),
        elevation: 6,
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
          child: Row(
            children: [
              Icon(error.icon, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  error.message,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              if (onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Повторить'),
                ),
              IconButton(
                onPressed: onClose,
                tooltip: 'Закрыть',
                icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ВИДЖЕТЫ ОФОРМЛЕНИЯ
// ═══════════════════════════════════════════════════════════════════════════

/// Полупрозрачное диалоговое окно с табличкой имени и «чипом» реплики игрока.
class _DialogueBox extends StatefulWidget {
  const _DialogueBox({
    required this.text,
    required this.speaker,
    required this.thinking,
    required this.playerLine,
    required this.maxHeight,
    required this.onTap,
  });

  final ValueListenable<String> text;
  final String speaker;
  final bool thinking;
  final String? playerLine;
  final double maxHeight;
  final VoidCallback onTap;

  @override
  State<_DialogueBox> createState() => _DialogueBoxState();
}

class _DialogueBoxState extends State<_DialogueBox> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.text.addListener(_stickToBottom);
  }

  @override
  void didUpdateWidget(covariant _DialogueBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      oldWidget.text.removeListener(_stickToBottom);
      widget.text.addListener(_stickToBottom);
    }
  }

  @override
  void dispose() {
    widget.text.removeListener(_stickToBottom);
    _scroll.dispose();
    super.dispose();
  }

  /// Длинная реплика не помещается — прокручиваем к последней строке,
  /// пока текст печатается.
  void _stickToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = widget.maxHeight;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      child: RepaintBoundary(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: double.infinity,
                constraints: BoxConstraints(
                  minHeight: math.min(132.0, maxHeight),
                  maxHeight: maxHeight,
                ),
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 16),
                decoration: BoxDecoration(
                  color: const Color(0xA6000000), // чёрный, ~65% непрозрачности
                  borderRadius: const BorderRadius.all(Radius.circular(18)),
                  border: Border.all(color: Colors.white24),
                ),
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: ValueListenableBuilder<String>(
                    valueListenable: widget.text,
                    builder: (context, value, _) => Text(
                      // Пока ответ ещё не начал приходить — многоточие.
                      value.isEmpty && widget.thinking ? '…' : value,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(left: 16, top: -14, child: _NamePlate(widget.speaker)),
              if (widget.playerLine != null)
                Positioned(
                  left: 150, // резервируем место под табличку имени
                  right: 16,
                  top: -14,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _PlayerChip(widget.playerLine!),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NamePlate extends StatelessWidget {
  const _NamePlate(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: const BoxDecoration(
        color: Color(0xFF7B4FA3),
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      child: Text(
        name,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 15,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _PlayerChip extends StatelessWidget {
  const _PlayerChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: const BoxDecoration(
        color: Color(0xE624324A),
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }
}

/// Строка ввода: поле + кнопка. Кнопка активна только в фазе idle
/// и только при непустом тексте.
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.phase,
    required this.onSend,
  });

  final TextEditingController controller;
  final _Phase phase;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 3,
              textInputAction: TextInputAction.send,
              textCapitalization: TextCapitalization.sentences,
              // Ограничение длины реплики — защита от случайной «простыни»
              // и лишних токенов.
              inputFormatters: [LengthLimitingTextInputFormatter(500)],
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white70,
              onSubmitted: (_) => onSend(), // защиту от дублей даёт _send()
              decoration: const InputDecoration(
                hintText: 'Скажите что-нибудь…',
                hintStyle: TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Color(0x99000000),
                contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Слушаем только контроллер: кнопка обновляется при вводе текста,
          // а весь экран — нет.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final canSend = phase == _Phase.idle && value.text.trim().isNotEmpty;
              return IconButton.filled(
                onPressed: canSend ? onSend : null,
                tooltip: 'Отправить',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF7B4FA3),
                  disabledBackgroundColor: const Color(0x66FFFFFF),
                ),
                icon: phase == _Phase.generating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_rounded, color: Colors.white),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Фон по умолчанию: тёмный градиент с мягким свечением за спрайтом.
class _DefaultBackground extends StatelessWidget {
  const _DefaultBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B1230), Color(0xFF0B0716), Color(0xFF000000)],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 0.9,
            colors: [Color(0x2EFFFFFF), Color(0x00000000)],
          ),
        ),
      ),
    );
  }
}

/// Заглушка на месте спрайта, пока нет настоящих ассетов.
class _SpritePlaceholder extends StatelessWidget {
  const _SpritePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Opacity(
      opacity: 0.35,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline_rounded, size: 160, color: Colors.white),
          SizedBox(height: 8),
          Text('Спрайт персонажа', style: TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}
