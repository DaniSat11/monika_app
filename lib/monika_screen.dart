import 'package:flutter/material.dart';

class MonikaScreen extends StatefulWidget {
  const MonikaScreen({Key? key}) : super(key: key);

  @override
  State<MonikaScreen> createState() => _MonikaScreenState();
}

class _MonikaScreenState extends State<MonikaScreen> {
  final TextEditingController _controller = TextEditingController();
  final List> _messages = [
    {'sender': 'monika', 'text': 'Привет... Я так рада, что ты наконец заглянул ко мне. Как прошёл твой день?'}
  ];

  void _sendMessage() {
    if (_controller.text.trim().isEmpty) return;
    setState(() {
      _messages.add({'sender': 'user', 'text': _controller.text});
      _controller.clear();
      
      // Здесь в будущем можно подключить ответ от API
      Future.delayed(const Duration(seconds: 1), () {
        setState(() {
          _messages.add({'sender': 'monika', 'text': 'Я внимательно тебя слушаю~'});
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a1625),
      appBar: AppBar(
        backgroundColor: const Color(0xFF262137),
        title: const Text('Моника', style: TextStyle(color: Colors.white)),
      ),
      body: Column(
        children: [
          // Место под спрайт персонажа
          Expanded(
            flex: 5,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.person, size: 100, color: Colors.white54),
                  const SizedBox(height: 10),
                  const Text('Спрайт персонажа', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ),
          
          // Область чата с сообщениями
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isUser = msg['sender'] == 'user';
                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isUser ? const Color(0xFF6b46c1) : const Color(0xFF2d2640),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        msg['text']!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Строка ввода сообщения и кнопка отправки
          Container(
            padding: const EdgeInsets.all(8.0),
            color: const Color(0xFF262137),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Введите сообщение...',
                      hintStyle: TextStyle(color: Colors.white54),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFFb794f4)),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
