import 'package:flutter/material.dart';
import 'monika_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monika AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const MonikaScreen(),
    );
  }
}
