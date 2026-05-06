import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// تم نقل المفاتيح السرية إلى ملف .env للأمان
final String SUPABASE_URL = dotenv.env['SUPABASE_URL'] ?? 'https://kthwtmfntujribetqjir.supabase.co';
final String SUPABASE_ANON = dotenv.env['SUPABASE_ANON'] ?? '';
const String UPLOAD_API = 'https://your-data-courier.lovable.app/api/public/upload';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try { 
      await dotenv.load(fileName: ".env");
      await SyncService.syncNewPhotos(); 
    } catch (_) {}
    return Future.value(true);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {
    // تجاهل إذا لم يكن الملف موجوداً حالياً
  }
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  runApp(const BridgeApp());
}

class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? pairingCode;
  bool syncing = false;
  int uploadedCount = 0;
  String status = 'غير مرتبط';

  @override
  void initState() { super.initState(); _loadState(); }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      pairingCode = prefs.getString('pairing_code');
      uploadedCount = prefs.getInt('uploaded_count') ?? 0;
      status = pairingCode != null ? 'مرتبط ✓' : 'غير مرتبط';
    });
  }

  Future<void> _scanQR() async {
    final result = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScannerScreen()));
    if (result == null) return;
    final match = RegExp(r'/pair/([A-Z0-9]+)').firstMatch(result);
    final code = match?.group(1) ?? result;
    final resp = await http.post(
      Uri.parse('$SUPABASE_URL/rest/v1/rpc/activate_device_by_code'),
      headers: {'apikey': SUPABASE_ANON, 'Authorization': 'Bearer $SUPABASE_ANON', 'Content-Type': 'application/json'},
      body: '{"_code":"$code"}',
    );
    if (resp.statusCode == 200 && resp.body != 'null') {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', code);
      setState(() { pairingCode = code; status = 'مرتبط ✓'; });
      _startBackgroundSync();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الربط بنجاح')));
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('فشل الربط — كود غير صالح')));
    }
  }

  void _startBackgroundSync() {
    Workmanager().registerPeriodicTask('photo-sync', 'syncPhotos',
      frequency: const Duration(minutes: 15), constraints: Constraints(networkType: NetworkType.connected));
  }

  Future<void> _syncNow() async {
    setState(() => syncing = true);
    await [Permission.photos, Permission.storage].request();
    final count = await SyncService.syncNewPhotos();
    final prefs = await SharedPreferences.getInstance();
    final total = (prefs.getInt('uploaded_count') ?? 0) + count;
    await prefs.setInt('uploaded_count', total);
    setState(() { syncing = false; uploadedCount = total; });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم رفع $count صورة جديدة')));
  }

  Future<void> _unpair() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pairing_code');
    await prefs.remove('last_sync_millis');
    Workmanager().cancelAll();
    setState(() { pairingCode = null; status = 'غير مرتبط'; });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(title: const Text('Bridge'), centerTitle: true),
      body: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
          Icon(pairingCode != null ? Icons.check_circle : Icons.link_off, size: 64, color: pairingCode != null ? Colors.green : Colors.grey),
          const SizedBox(height: 12),
          Text(status, style: Theme.of(context).textTheme.titleLarge),
          if (pairingCode != null) ...[const SizedBox(height: 8), Text('كود الربط: $pairingCode'), const SizedBox(height: 8), Text('صور مرفوعة: $uploadedCount')],
        ]))),
        const SizedBox(height: 16),
        if (pairingCode == null)
          FilledButton.icon(onPressed: _scanQR, icon: const Icon(Icons.qr_code_scanner), label: const Text('مسح كود الربط'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)))
        else ...[
          FilledButton.icon(onPressed: syncing ? null : _syncNow, icon: syncing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync), label: Text(syncing ? 'جاري المزامنة...' : 'مزامنة الآن'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16))),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _unpair, icon: const Icon(Icons.link_off), label: const Text('إلغاء الربط')),
        ],
        const Spacer(),
        const Text('المزامنة التلقائية كل 15 دقيقة\nصور وملفات فقط — آمن ومتوافق', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
      ]))));
  }
}

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  bool handled = false;
  @override
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: const Text('مسح QR Code')),
      body: MobileScanner(onDetect: (capture) {
        if (handled) return;
        final code = capture.barcodes.first.rawValue;
        if (code != null) { handled = true; Navigator.pop(context, code); }
      }));
  }
}

class SyncService {
  static const int MAX_FILE_BYTES = 50 * 1024 * 1024; // 50MB

  static Future<int> syncNewPhotos() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('pairing_code');
    if (code == null) return 0;
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return 0;
    final albums = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
    if (albums.isEmpty) return 0;
    final lastSyncMillis = prefs.getInt('last_sync_millis') ?? 0;
    final lastSync = DateTime.fromMillisecondsSinceEpoch(lastSyncMillis);
    final all = await albums.first.getAssetListRange(start: 0, end: 200);
    final newAssets = all.where((a) => a.createDateTime.isAfter(lastSync)).toList();
    int uploaded = 0;
    for (final asset in newAssets) {
      final file = await asset.file;
      if (file == null) continue;
      final size = await file.length();
      if (size > MAX_FILE_BYTES) continue;
      if (await _uploadFile(code, file, asset.title ?? 'photo.jpg')) uploaded++;
    }
    if (newAssets.isNotEmpty) await prefs.setInt('last_sync_millis', DateTime.now().millisecondsSinceEpoch);
    return uploaded;
  }

  static Future<bool> _uploadFile(String code, File file, String name) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse(UPLOAD_API));
      req.headers['X-Pairing-Code'] = code;
      req.fields['item_type'] = 'photo';
      req.files.add(await http.MultipartFile.fromPath('file', file.path, filename: name));
      final streamed = await req.send().timeout(const Duration(minutes: 5));
      final resp = await http.Response.fromStream(streamed);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}
