import 'package:flutter/material.dart';

import 'core/controller.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final VeloController controller = VeloController();
  runApp(VeloApp(controller: controller));
  await controller.init();
}

class VeloApp extends StatelessWidget {
  const VeloApp({super.key, required this.controller});

  final VeloController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Velo',
      debugShowCheckedModeBanner: false,
      theme: veloTheme(),
      home: HomePage(controller: controller),
    );
  }
}
