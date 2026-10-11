import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'screens/projects_screen.dart';
import 'screens/history_screen.dart';
import 'screens/trash_screen.dart';
import 'models/inference_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to landscape orientation (microplate images are wide)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Request permissions
  await _requestPermissions();

  // Initialize inference service (load models)
  await InferenceService().initialize();

  runApp(const MicroplateAnalyzerApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.camera,
    Permission.storage,
    Permission.photos,
  ].request();
}

class MicroplateAnalyzerApp extends StatelessWidget {
  const MicroplateAnalyzerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Microplate Analyzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const MainScreen(),
      routes: {
        '/history': (context) => const HistoryScreen(),
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0; // Start on Projects — work begins from a project

  // Keys to trigger refresh when a tab becomes visible again
  // (IndexedStack keeps screens mounted, so initState runs only once)
  final _projectsKey = GlobalKey<ProjectsScreenState>();
  final _historyKey = GlobalKey<HistoryScreenState>();
  final _trashKey = GlobalKey<TrashScreenState>();

  late final List<Widget> _screens = [
    ProjectsScreen(key: _projectsKey),
    HistoryScreen(key: _historyKey),
    TrashScreen(key: _trashKey),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack keeps all screens mounted → state preserved across tab switches
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        height: 56,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
          // Refresh data-driven tabs when they become visible
          if (index == 0) _projectsKey.currentState?.refresh();
          if (index == 1) _historyKey.currentState?.refresh();
          if (index == 2) _trashKey.currentState?.refresh();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            label: 'Projects',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.delete_outline),
            label: 'Trash',
          ),
        ],
      ),
    );
  }
}
