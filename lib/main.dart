import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'screens/lobby_screen.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';

/// Brand palette — dark terminal aesthetic, green = profit/direction, red =
/// losses. Values mirror the shipped web frontend.
class AppColors {
  AppColors._();

  static const Color bg = Color(0xFF0C0F0D);
  static const Color panel = Color(0xFF131714);
  static const Color line = Color(0xFF1E2420);
  static const Color ink = Color(0xFFE6E6E6);
  static const Color dim = Color(0xFF8B938E);
  static const Color green = Color(0xFF22C55E);
  static const Color red = Color(0xFFE05252);
  static const Color gold = Color(0xFFE0A752);
}

/// Join-order chart palette (carried over from the web app verbatim). Indexed
/// by `joined_at` ascending so a player is the same color in every view.
const List<Color> chartPalette = [
  Color(0xFF44C723), // green
  Color(0xFFE0A752), // gold
  Color(0xFF528BE0), // blue
  Color(0xFFC72386), // magenta
  Color(0xFFD3E87D), // lime
  Color(0xFFD37DE8), // violet
  Color(0xFFD4D4D8), // silver
  Color(0xFFE05252), // red
  Color(0xFF52E0E0), // cyan
  Color(0xFF4423C7), // indigo
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CompeteApp());
}

class CompeteApp extends StatelessWidget {
  const CompeteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StableTraderX',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.green,
          secondary: AppColors.green,
          surface: AppColors.panel,
          error: AppColors.red,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.bg,
          foregroundColor: AppColors.ink,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppColors.panel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.green, width: 1.5),
          ),
          labelStyle: const TextStyle(color: AppColors.dim),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.black,
            minimumSize: const Size.fromHeight(48),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      home: const Root(),
    );
  }
}

/// Auth gate: restore a persisted session, else show login. Holds the single
/// shared [ApiClient] + [AuthService] for the whole app.
class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  final ApiClient _api = ApiClient();
  final AuthService _auth = AuthService();
  bool _loading = true;
  String? _username;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final u = await _auth.restore(_api);
    if (!mounted) return;
    setState(() {
      _username = u;
      _api.userAddress = u == null ? null : 'u:${u.toLowerCase()}';
      _loading = false;
    });
  }

  void _onAuthed(String username) {
    setState(() {
      _username = username;
      _api.userAddress = 'u:${username.toLowerCase()}';
    });
  }

  Future<void> _logout() async {
    await _auth.logout();
    _api.token = null;
    if (!mounted) return;
    setState(() => _username = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_username == null) {
      return LoginScreen(api: _api, auth: _auth, onAuthed: _onAuthed);
    }
    return LobbyScreen(api: _api, username: _username!, onLogout: _logout);
  }
}