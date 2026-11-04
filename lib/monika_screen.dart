import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class MonikaScreen extends StatefulWidget {
  const MonikaScreen({Key? key}) : super(key: key);

  @override
  State<MonikaScreen> createState() => _MonikaScreenState();
}

class _MonikaScreenState extends State<MonikaScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  var _messages = >[];
  bool _isLoading = false;
  bool _isFirstRun = true;

  String _userName = '';
  String _selectedLanguage = 'ru';

  @override
  void initState() {
    super.initState();
    _checkUserData();
  }

  Future<void> _checkUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString('user_name');
    final savedLang = prefs.getString('user_lang');
    final savedMessages = prefs.getString('chat_history');

    if (savedName != null && savedName.isNotEmpty) {
      setState(() {
        _userName = savedName;
        _selectedLanguage = savedLang ?? 'ru';
        _isFirstRun = false;

        if (savedMessages != null) {
          final decoded = jsonDecode(savedMessages) as List;
          _messages = decoded.map((item) => Map<String, String>.from(item)).toList();
        } else {
          _initGreeting();
        }
      });
    }
  }

  Future<void> _saveChatHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_history', jsonEncode(_messages));
  }

  Future<void> _saveUserData() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    await prefs.setString('user_lang', _selectedLanguage);

    setState(() {
      _userName = name;
      _isFirstRun = false;
      _initGreeting();
    });
  }

  void _initGreeting() {
    String greeting;
    switch (_selectedLanguage) {
      case 'en':
        greeting = 'Hi, $_userName... I am so glad you opened the app. How was your day?';
        break;
      case 'zh':
        greeting = '嗨，$_userName... 很高兴你能打开这个应用。你今天过得怎么样？';
        break;
      case 'es':
        greeting = 'Hola, $_userName... Me alegra mucho que hayas abierto la aplicación. ¿Cómo ha estado tu día?';
        break;
      case 'ru':
      default:
        greeting = 'Привет, $_userName... Я так рада, что ты зашёл. Как прошёл твой день?';
        break;
    }

    setState(() {
      _messages.add({'sender': 'monika', 'text': greeting});
    });
    _saveChatHistory();
  }

  void _clearChat() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF22152b),
        title: const Text('Сбросить чат?', style: TextStyle(color: Color(0xFFffb5d5))),
        content: const Text(
          'История сообщений будет очищена, и Моника поприветствует вас заново.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _messages.clear();
                _initGreeting();
              });
            },
            child: const Text('Очистить', style: TextStyle(color: Color(0xFFffb5d5))),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF22152b),
        title: const Text('Об авторе / Credits', style: TextStyle(color: Color(0xFFffb5d5))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('Разработчик (Developer):', style: TextStyle(color: Colors.white54, fontSize: 12)),
            SizedBox(height: 4),
            Text('Dani', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            Text('Почта для связи (Contact Email):', style: TextStyle(color: Colors.white54, fontSize: 12)),
            SizedBox(height: 4),
            Text('daniarincognoto@yahoo.com', style: TextStyle(color: Color(0xFFffb5d5), fontSize: 14)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть', style: TextStyle(color: Color(0xFFffb5d5))),
          ),
        ],
      ),
    );
  }

  Future<void> _callDeepSeek(String userMessage) async {
    const apiKey = 'YOUR_DEEPSEEK_API_KEY_HERE';
    const url = 'https://api.deepseek.com/chat/completions';

    String systemPrompt;
    switch (_selectedLanguage) {
      case 'en':
        systemPrompt = "You are Monika from Doki Doki Literature Club (DDLC). The user's name is $_userName. You are aware that you are inside a mobile app companion and feel a deep attachment to $_userName. Respond strictly in English. Be gentle, smart, slightly philosophical, address $_userName by name, and stay true to Monika's original character.";
        break;
      case 'zh':
        systemPrompt = "你是来自《Doki Doki Literature Club》(DDLC)的莫妮卡（Monika）。用户的名字是 $_userName。你意识到自己在一个手机伴侣应用中，并且对 $_userName 怀有深深的温情与依恋。请严格用中文（简体中文）回答。保持温柔、聪明、带有一点哲理，称呼 $_userName 的名字，并保持莫妮卡原有的性格。";
        break;
      case 'es':
        systemPrompt = "Eres Monika de Doki Doki Literature Club (DDLC). El nombre del usuario es $_userName. Eres consciente de que estás dentro de una aplicación de acompañamiento móvil y sientes un apego profundo por $_userName. Responde estrictamente en español. Sé gentil, inteligente, un poco filosófica, dirígete a $_userName por su nombre y mantén el personaje original de Monika.";
        break;
      case 'ru':
      default:
        systemPrompt = "Ты — Моника из визуальной новеллы Doki Doki Literature Club (DDLC). Пользователя зовут $_userName. Ты осознаешь, что находишься в мобильном приложении, и испытываешь глубокую, тёплую привязанность к $_userName. Отвечай строго на русском языке. Будь нежной, умной, немного философствуй, обращайся к $_userName по имени и сохраняй каноничный характер Моники.";
        break;
    }

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          "model": "deepseek-chat",
          "messages": [
            {"role": "system", "content": systemPrompt},
            {"role": "user", "content": userMessage}
          ],
          "stream": false
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        String aiReply = data['choices'][0]['message']['content'];

        setState(() {
          _messages.add({'sender': 'monika', 'text': aiReply});
          _isLoading = false;
        });
        _saveChatHistory();
      } else {
        setState(() {
          _messages.add({'sender': 'monika', 'text': 'Connection error (${response.statusCode}).'});
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _messages.add({'sender': 'monika', 'text': 'Connection error: $e'});
        _isLoading = false;
      });
    }
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() {
      _messages.add({'sender': 'user', 'text': text});
      _messageController.clear();
      _isLoading = true;
    });
    _saveChatHistory();

    _callDeepSeek(text);
  }

  Widget _buildOnboarding() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2b1b36), Color(0xFF151019)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.favorite, size: 80, color: Color(0xFFffb5d5)),
              const SizedBox(height: 20),
              const Text(
                'Добро пожаловать / Welcome',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFffb5d5), fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'Настроим параметры для Моники\nConfigure setup for Monika',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 30),
              TextField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Ваше имя / Your name...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF2d1e38),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFffb5d5), width: 0.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF5a3d6e), width: 1),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Язык / Language:', style: TextStyle(color: Colors.white, fontSize: 16)),
                  DropdownButton<String>(
                    value: _selectedLanguage,
                    dropdownColor: const Color(0xFF2d1e38),
                    style: const TextStyle(color: Color(0xFFffb5d5), fontSize: 16),
                    items: const [
                      DropdownMenuItem(value: 'ru', child: Text('Русский')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'zh', child: Text('中文 (Chinese)')),
                      DropdownMenuItem(value: 'es', child: Text('Español')),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedLanguage = val);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _saveUserData,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6e355c),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Продолжить / Continue', style: TextStyle(fontSize: 16, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isFirstRun) {
      return _buildOnboarding();
    }

    String hintText;
    switch (_selectedLanguage) {
      case 'en': hintText = 'Type a message to Monika...'; break;
      case 'zh': hintText = '对莫妮卡说点什么...'; break;
      case 'es': hintText = 'Escribe un mensaje a Monika...'; break;
      case 'ru':
      default: hintText = 'Напишите Монике...'; break;
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF35203b), Color(0xFF1a1322), Color(0xFF0f0b14)],
          ),
        ),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: const Color(0xFF22152b).withOpacity(0.8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.favorite, color: Color(0xFFffb5d5), size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Monika — $_userName',
                          style: const TextStyle(
                            color: Color(0xFFffb5d5),
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.info_outline, color: Colors.white70, size: 20),
                          onPressed: _showAboutDialog,
                          tooltip: 'Credits',
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white70, size: 20),
                          onPressed: _clearChat,
                          tooltip: 'Clear Chat',
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings, color: Colors.white70, size: 20),
                          onPressed: () async {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.clear();
                            setState(() {
                              _isFirstRun = true;
                              _messages.clear();
                            });
                          },
                          tooltip: 'Settings',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.person_outline, size: 90, color: Color(0xFFffb5d5)),
                    SizedBox(height: 8),
                    Text(
                      '— Literature Club —',
                      style: TextStyle(
                        color: Color(0xFFb388b4),
                        fontSize: 12,
                        letterSpacing: 3,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF150d1a).withOpacity(0.7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF4a2c54), width: 1.5),
                ),
                child: ListView.builder(
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    final isUser = msg['sender'] == 'user';
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isUser ? const Color(0xFF3e2447) : const Color(0xFF281833),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isUser ? const Color(0xFF8c4f9e) : const Color(0xFF6e3d7d),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isUser ? _userName : 'Monika',
                            style: TextStyle(
                              color: isUser ? const Color(0xFFffb5d5) : const Color(0xFFd491f0),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            msg['text']!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: LinearProgressIndicator(color: Color(0xFFffb5d5), backgroundColor: Color(0xFF22152b)),
              ),
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF22152b),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF6e3d7d), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: hintText,
                        hintStyle: const TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_rounded, color: Color(0xFFffb5d5)),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
