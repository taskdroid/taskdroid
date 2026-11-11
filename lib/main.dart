import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskdroid/providers/app_state.dart';
import 'package:taskdroid/providers/profile_state.dart';
import 'package:taskdroid/providers/task_state.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/src/rust/frb_generated.dart';
import 'package:taskdroid/views/home.dart';
import 'package:taskdroid/views/credentials.dart';
import 'package:taskdroid/views/settings.dart';
import 'package:taskdroid/views/data_management.dart';
import 'package:taskdroid/theme/app_theme.dart';
import 'package:taskdroid/widgets/common/app_sheet.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // ureq caches its root store on the first HTTPS request, so the trust
  // setting has to be applied before the UI can trigger any network call
  final prefs = await SharedPreferences.getInstance();
  configureTls(
    trustUserCerts: prefs.getBool(AppState.trustUserCertsKey) ?? false,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AppState()),
        ChangeNotifierProvider(create: (context) => ProfileState()),
        ChangeNotifierProvider(create: (context) => TaskState()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return MaterialApp(
          title: 'Taskdroid',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: appState.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
          // Tapping dead space anywhere dismisses the keyboard, sheets
          // included. Buttons, list tiles and fields win the gesture arena;
          // only taps that nothing else claims reach this.
          builder: (context, child) => AppTapToDismiss(child: child),
          initialRoute: '/',
          routes: {
            '/': (context) => const HomePage(),
            '/credentials': (context) => const CredentialsPage(),
            '/data': (context) => const DataManagementPage(),
            '/settings': (context) => const SettingsPage(),
          },
        );
      },
    );
  }
}
