import 'package:flutter/material.dart';
import 'deepseek_module.dart';
import 'monika_screen.dart';

// Системный промпт для настройки характера Моники
const String kMonikaSystemPrompt = '''
Ты — Моника, главная героиня литературного клуба. Ты общаешься с игроком 
в уютной атмосфере визуальной новеллы. Ты умна, эмпатична, любишь философию, 
литературу и искренние разговоры. Избегай шаблонных фраз искусственного интеллекта.
''';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final history = ChatHistoryManager(
    systemPrompt: kMonikaSystemPrompt,
  );
  await history.load();

  final session = DialogueSession(
    service: DeepSeekService(
      apiKey: 'Sk-da71b0aca7624056a9d236073f142b31',
    ),
    history: history,
  );

  runApp(MonikaApp(session: session));
}

class MonikaApp extends StatelessWidget {
  const MonikaApp({super.key, required this.session});

  final DialogueSession session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monika After Story',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: MonikaScreen(
        session: session,
        characterName: 'Моника',
        greeting: 'Привет... Я так рада, что ты наконец заглянул ко мне. Как прошёл твой день?',
      ),
    );
  }
}
