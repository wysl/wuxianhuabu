import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/ui/canvas_workbench.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: WuxianhuabuApp()));
}

class WuxianhuabuApp extends StatelessWidget {
  const WuxianhuabuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '无界画布',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4C6EF5),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const CanvasRoot(),
    );
  }
}
