import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:network_info_plus/network_info_plus.dart';

void main() {
  runApp(const PaupaulTransfertApp());
}

// ─────────────────────────────────────────────
// DESIGN TOKENS
// ─────────────────────────────────────────────
class _T {
  // Colors
  static const bg         = Color(0xFF090909);
  static const surface    = Color(0xFF141414);
  static const card       = Color(0xFF1C1C1E);
  static const border     = Color(0x1AFFFFFF); // white 10%
  static const label      = Color(0xFFFFFFFF);
  static const secondary  = Color(0xFF8E8E93); // iOS secondary
  static const accent     = Color(0xFF0A84FF); // iOS Blue
  static const green      = Color(0xFF30D158); // iOS Green
  static const red        = Color(0xFFFF453A); // iOS Red
  static const orange     = Color(0xFFFF9F0A);

  // Typography
  static const fontLight  = FontWeight.w300;
  static const fontReg    = FontWeight.w400;
  static const fontMed    = FontWeight.w500;
  static const fontSemi   = FontWeight.w600;

  // Radius
  static const r8  = BorderRadius.all(Radius.circular(8));
  static const r12 = BorderRadius.all(Radius.circular(12));
  static const r16 = BorderRadius.all(Radius.circular(16));
  static const r20 = BorderRadius.all(Radius.circular(20));

  static TextStyle mono(double size, {Color color = label, FontWeight fw = fontLight}) =>
      TextStyle(fontFamily: 'monospace', fontSize: size, color: color, fontWeight: fw, height: 1.2);
}

// ─────────────────────────────────────────────
// MODEL
// ─────────────────────────────────────────────
class TransferRecord {
  final String fileName;
  final int sizeBytes;
  final DateTime date;
  final double speedMBs;
  TransferRecord({
    required this.fileName,
    required this.sizeBytes,
    required this.date,
    required this.speedMBs,
  });
}

// ─────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────
class PaupaulTransfertApp extends StatelessWidget {
  const PaupaulTransfertApp({super.key});

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'Paupaul Transfert',
      debugShowCheckedModeBanner: false,
      theme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: _T.accent,
        scaffoldBackgroundColor: _T.bg,
        textTheme: CupertinoTextThemeData(
          textStyle: TextStyle(
            fontFamily: '.SF Pro Text',
            color: _T.label,
          ),
        ),
      ),
      home: const TransferHomePage(),
    );
  }
}

// ─────────────────────────────────────────────
// HOME PAGE
// ─────────────────────────────────────────────
class TransferHomePage extends StatefulWidget {
  const TransferHomePage({super.key});
  @override
  State<TransferHomePage> createState() => _TransferHomePageState();
}

class _TransferHomePageState extends State<TransferHomePage>
    with TickerProviderStateMixin {

  // ── Server ─────────────────────────────────
  HttpServer? _server;
  bool _isRunning = false;
  String _ipAddress = '—';
  final int _port = 8080;
  final List<TransferRecord> _transfers = [];

  // ── Mode segmented (0 = Wi-Fi, 1 = USB) ───
  int _selectedMode = 0;

  // ── Speed ──────────────────────────────────
  double _speedMBs   = 0.0;
  double _peakMBs    = 0.0;
  int _bytesWindow   = 0;
  int _sessionBytes  = 0;
  bool _active       = false;
  Timer? _ticker;
  double _lastTransferSpeed = 0.0;

  static const double _maxSpeed = 120.0; // MB/s scale

  // ── Animations ─────────────────────────────
  late AnimationController _ringCtrl;
  late AnimationController _pulseCtrl;
  Animation<double>? _ringAnim;
  late Animation<double> _pulseAnim;

  // ─────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _ringAnim = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _ringCtrl, curve: Curves.easeOutCubic),
    );

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _fetchIP();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ringCtrl.dispose();
    _pulseCtrl.dispose();
    _server?.close(force: true);
    super.dispose();
  }

  // ─── IP ────────────────────────────────────
  Future<void> _fetchIP() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (mounted) setState(() => _ipAddress = ip ?? '—');
    } catch (_) {
      if (mounted) setState(() => _ipAddress = 'Réseau indisponible');
    }
  }

  // ─── Ring animation ────────────────────────
  void _animateRingTo(double ratio) {
    final from = _ringAnim?.value ?? 0.0;
    final to   = ratio.clamp(0.0, 1.0);
    _ringAnim  = Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: _ringCtrl, curve: Curves.easeOutCubic),
    );
    _ringCtrl..reset()..forward();
  }

  // ─── Speed ticker ──────────────────────────
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = _bytesWindow / (1024 * 1024);
      setState(() {
        _speedMBs = s;
        if (s > _peakMBs) _peakMBs = s;
        _active   = _bytesWindow > 0;
        _bytesWindow = 0;
      });
      _animateRingTo(s / _maxSpeed);
    });
  }

  // ─── Server start ──────────────────────────
  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      setState(() {
        _isRunning    = true;
        _sessionBytes = 0;
        _peakMBs      = 0;
        _speedMBs     = 0;
        _active       = false;
      });
      _startTicker();
      _server!.listen(_handleRequest);
    } catch (e) {
      _toast('Erreur : $e');
    }
  }

  void _handleRequest(HttpRequest req) {
    if (req.method == 'POST') {
      _handleUpload(req);
    } else {
      req.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('POST only')
        ..close();
    }
  }

  Future<void> _handleUpload(HttpRequest req) async {
    try {
      final dir      = await getApplicationDocumentsDirectory();
      final name     = req.headers.value('x-filename') ??
          'file_${DateTime.now().millisecondsSinceEpoch}';
      final file     = File('${dir.path}/$name');
      final sink     = file.openWrite();
      int fileBytes  = 0;
      final t0       = DateTime.now();

      await for (final chunk in req) {
        sink.add(chunk);
        fileBytes      += chunk.length;
        _bytesWindow   += chunk.length;
        _sessionBytes  += chunk.length;
      }

      await sink.flush();
      await sink.close();

      final elapsed = DateTime.now().difference(t0).inMilliseconds / 1000;
      _lastTransferSpeed = elapsed > 0
          ? (fileBytes / (1024 * 1024)) / elapsed
          : 0.0;

      if (mounted) {
        setState(() {
          _transfers.insert(0, TransferRecord(
            fileName:  name,
            sizeBytes: fileBytes,
            date:      DateTime.now(),
            speedMBs:  _lastTransferSpeed,
          ));
          if (_transfers.length > 30) _transfers.removeLast();
        });
      }

      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok","file":"$name","bytes":$fileBytes}')
        ..close();
    } catch (e) {
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write('{"error":"$e"}')
        ..close();
    }
  }

  Future<void> _stopServer() async {
    _ticker?.cancel();
    await _server?.close(force: true);
    setState(() {
      _server   = null;
      _isRunning = false;
      _active   = false;
    });
    _animateRingTo(0.0);
    await Future.delayed(const Duration(milliseconds: 750));
    if (mounted) setState(() => _speedMBs = 0.0);
  }

  // ─── File picker ───────────────────────────
  Future<void> _pickAndServeFile() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;

    final names = result.files.map((f) => f.name).join(', ');
    _toast('${result.files.length} fichier(s) sélectionné(s) : $names');
    // Ici vous pouvez ajouter la logique d'envoi custom si nécessaire
  }

  void _toast(String msg) {
    showCupertinoDialog(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Paupaul Transfert'),
        content: Text(msg),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: _T.bg,
      child: Stack(
        children: [
          // Subtle ambient gradient
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.8),
                  radius: 1.2,
                  colors: [
                    const Color(0xFF0A84FF).withOpacity(0.06),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      _buildNavBar(),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            _buildModeSelector(),
                            const SizedBox(height: 16),
                            _buildRingCard(),
                            const SizedBox(height: 12),
                            _buildProgressCard(),
                            const SizedBox(height: 12),
                            _buildConnectionCard(),
                            const SizedBox(height: 12),
                            _buildShareButton(),
                            const SizedBox(height: 20),
                            _buildHistory(),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Bottom action bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildActionBar(),
          ),
        ],
      ),
    );
  }

  // ─── NAV BAR ───────────────────────────────
  Widget _buildNavBar() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Paupaul',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: _T.label,
                      letterSpacing: -0.5,
                      height: 1.1,
                    ),
                  ),
                  const Text(
                    'Transfert',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: _T.fontLight,
                      color: _T.label,
                      letterSpacing: -0.5,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Serveur HTTP local · port $_port',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: _T.fontReg,
                      color: _T.secondary,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildLiveIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveIndicator() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (_isRunning ? _T.green : _T.secondary).withOpacity(0.12),
          borderRadius: _T.r20,
          border: Border.all(
            color: (_isRunning ? _T.green : _T.secondary).withOpacity(0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRunning
                    ? _T.green.withOpacity(_pulseAnim.value)
                    : _T.secondary.withOpacity(0.5),
                boxShadow: _isRunning
                    ? [BoxShadow(
                        color: _T.green.withOpacity(0.4 * _pulseAnim.value),
                        blurRadius: 6,
                      )]
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _isRunning ? 'Live' : 'Arrêté',
              style: TextStyle(
                fontSize: 12,
                fontWeight: _T.fontMed,
                color: _isRunning ? _T.green : _T.secondary,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── MODE SELECTOR ─────────────────────────
  Widget _buildModeSelector() {
    return _AppleCard(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _SegmentTab(
            icon: CupertinoIcons.wifi,
            label: 'Wi-Fi',
            selected: _selectedMode == 0,
            onTap: () => setState(() => _selectedMode = 0),
          ),
          _SegmentTab(
            icon: CupertinoIcons.bolt_fill,
            label: 'USB',
            selected: _selectedMode == 1,
            onTap: () => setState(() => _selectedMode = 1),
          ),
        ],
      ),
    );
  }

  // ─── RING CARD ─────────────────────────────
  Widget _buildRingCard() {
    return _AppleCard(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        children: [
          Text(
            'VITESSE',
            style: TextStyle(
              fontSize: 11,
              fontWeight: _T.fontMed,
              color: _T.secondary.withOpacity(0.7),
              letterSpacing: 2.0,
            ),
          ),
          const SizedBox(height: 28),
          AnimatedBuilder(
            animation: Listenable.merge([
              _ringAnim ?? _ringCtrl,
              _pulseCtrl,
            ]),
            builder: (_, __) {
              final val = _ringAnim?.value ?? 0.0;
              return SizedBox(
                width: 200,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(200, 200),
                      painter: _ThinRingPainter(
                        progress: val,
                        isActive: _active,
                        pulseValue: _pulseAnim.value,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _speedMBs >= 100
                              ? _speedMBs.toStringAsFixed(1)
                              : _speedMBs.toStringAsFixed(2),
                          style: TextStyle(
                            fontSize: 52,
                            fontWeight: _T.fontLight,
                            color: _active ? _T.label : _T.secondary,
                            letterSpacing: -2,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'MB/s',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: _T.fontReg,
                            color: _T.secondary,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 28),
          // Stats row
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _statCell(
                    label: 'Pic',
                    value: _peakMBs.toStringAsFixed(1),
                    unit: 'MB/s',
                    icon: CupertinoIcons.bolt_fill,
                    color: _T.orange,
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  color: _T.border,
                ),
                Expanded(
                  child: _statCell(
                    label: 'Fichiers',
                    value: '${_transfers.length}',
                    unit: 'transférés',
                    icon: CupertinoIcons.doc_fill,
                    color: _T.accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCell({
    required String label,
    required String value,
    required String unit,
    required IconData icon,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: _T.secondary, letterSpacing: 0.3)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value,
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: _T.fontSemi,
                          color: color,
                          letterSpacing: -0.5)),
                  const SizedBox(width: 3),
                  Text(unit,
                      style: const TextStyle(
                          fontSize: 11, color: _T.secondary)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── PROGRESS CARD ─────────────────────────
  Widget _buildProgressCard() {
    const double maxBytes = 5.0 * 1024 * 1024 * 1024;
    final double ratio = (_sessionBytes / maxBytes).clamp(0.0, 1.0);

    return _AppleCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(CupertinoIcons.arrow_down_circle_fill,
                      size: 15, color: _T.accent),
                  const SizedBox(width: 7),
                  const Text('Données reçues',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: _T.fontMed,
                          color: _T.label)),
                ],
              ),
              Text(
                '${_formatBytes(_sessionBytes)} / 5 GB',
                style: const TextStyle(fontSize: 13, color: _T.secondary),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(
                  height: 3,
                  color: Colors.white.withOpacity(0.07),
                ),
                AnimatedFractionallySizedBox(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOut,
                  widthFactor: ratio,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: _T.accent,
                      boxShadow: [
                        BoxShadow(
                          color: _T.accent.withOpacity(0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── CONNECTION CARD ───────────────────────
  Widget _buildConnectionCard() {
    final url = _selectedMode == 0
        ? 'http://$_ipAddress:$_port'
        : 'http://localhost:$_port';

    return _AppleCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _connRow(
            icon: CupertinoIcons.antenna_radiowaves_left_right,
            label: _selectedMode == 0 ? 'Adresse Wi-Fi' : 'Interface USB',
            value: _selectedMode == 0 ? _ipAddress : 'localhost',
            valueColor: _T.accent,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: _T.border),
          ),
          _connRow(
            icon: CupertinoIcons.link,
            label: 'Endpoint POST',
            value: url,
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.04),
              borderRadius: _T.r12,
              border: Border.all(color: _T.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('En-tête requis',
                    style: TextStyle(
                        fontSize: 10,
                        color: _T.secondary.withOpacity(0.6),
                        letterSpacing: 1.2)),
                const SizedBox(height: 6),
                Text(
                  'x-filename: nom_du_fichier.ext',
                  style: _T.mono(12, color: _T.label),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _connRow({
    required IconData icon,
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: _T.secondary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11, color: _T.secondary, letterSpacing: 0.3)),
              const SizedBox(height: 1),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: _T.fontMed,
                  color: valueColor ?? _T.label,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── SHARE BUTTON ──────────────────────────
  Widget _buildShareButton() {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: _pickAndServeFile,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: _T.accent.withOpacity(0.1),
          borderRadius: _T.r16,
          border: Border.all(color: _T.accent.withOpacity(0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(CupertinoIcons.square_arrow_up, color: _T.accent, size: 18),
            SizedBox(width: 8),
            Text(
              'Partager des fichiers',
              style: TextStyle(
                fontSize: 15,
                fontWeight: _T.fontMed,
                color: _T.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── HISTORY ───────────────────────────────
  Widget _buildHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              const Text(
                'Historique',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: _T.fontSemi,
                  color: _T.label,
                  letterSpacing: -0.3,
                ),
              ),
              const Spacer(),
              if (_transfers.isNotEmpty)
                Text(
                  '${_transfers.length}',
                  style: const TextStyle(
                    fontSize: 15,
                    color: _T.secondary,
                  ),
                ),
            ],
          ),
        ),
        if (_transfers.isEmpty)
          _AppleCard(
            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
            child: Center(
              child: Column(
                children: [
                  const Icon(CupertinoIcons.tray,
                      color: _T.secondary, size: 28),
                  const SizedBox(height: 10),
                  Text(
                    'Aucun fichier reçu',
                    style: TextStyle(
                      fontSize: 15,
                      color: _T.secondary.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          _AppleCard(
            padding: EdgeInsets.zero,
            child: ListView.separated(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              itemCount: _transfers.length,
              separatorBuilder: (_, __) => Padding(
                padding: const EdgeInsets.only(left: 60),
                child: Divider(height: 1, color: _T.border),
              ),
              itemBuilder: (_, i) => _buildHistoryRow(_transfers[i], i == 0),
            ),
          ),
      ],
    );
  }

  Widget _buildHistoryRow(TransferRecord r, bool isFirst) {
    final ext = r.fileName.contains('.')
        ? r.fileName.split('.').last.toLowerCase()
        : '?';
    final time =
        '${r.date.hour.toString().padLeft(2, '0')}:${r.date.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _T.accent.withOpacity(0.12),
              borderRadius: _T.r8,
            ),
            child: Center(
              child: Text(
                ext.length > 3 ? ext.substring(0, 3) : ext,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: _T.fontSemi,
                  color: _T.accent,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.fileName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: _T.fontMed,
                    color: _T.label,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${_formatBytes(r.sizeBytes)}  ·  ${r.speedMBs.toStringAsFixed(1)} MB/s',
                  style: const TextStyle(fontSize: 12, color: _T.secondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Icon(CupertinoIcons.checkmark_circle_fill,
                  color: _T.green, size: 15),
              const SizedBox(height: 3),
              Text(time,
                  style: const TextStyle(
                      fontSize: 11, color: _T.secondary)),
            ],
          ),
        ],
      ),
    );
  }

  // ─── ACTION BAR ────────────────────────────
  Widget _buildActionBar() {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          padding: EdgeInsets.fromLTRB(
              16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
          decoration: BoxDecoration(
            color: _T.bg.withOpacity(0.8),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.08)),
            ),
          ),
          child: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _isRunning ? _stopServer : _startServer,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 54,
              decoration: BoxDecoration(
                color: _isRunning
                    ? _T.red.withOpacity(0.15)
                    : _T.accent.withOpacity(0.15),
                borderRadius: _T.r20,
                border: Border.all(
                  color: _isRunning
                      ? _T.red.withOpacity(0.3)
                      : _T.accent.withOpacity(0.3),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isRunning
                        ? CupertinoIcons.stop_circle
                        : CupertinoIcons.play_circle_fill,
                    color: _isRunning ? _T.red : _T.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _isRunning ? 'Arrêter le serveur' : 'Démarrer le serveur',
                      key: ValueKey(_isRunning),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: _T.fontSemi,
                        color: _isRunning ? _T.red : _T.accent,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── HELPERS ───────────────────────────────
  String _formatBytes(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

// ─────────────────────────────────────────────
// SEGMENT TAB
// ─────────────────────────────────────────────
class _SegmentTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          height: 40,
          decoration: BoxDecoration(
            color: selected ? Colors.white.withOpacity(0.1) : Colors.transparent,
            borderRadius: _T.r16,
            border: Border.all(
              color: selected
                  ? Colors.white.withOpacity(0.15)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 14,
                  color: selected ? _T.label : _T.secondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? _T.fontMed : _T.fontReg,
                  color: selected ? _T.label : _T.secondary,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// APPLE CARD
// ─────────────────────────────────────────────
class _AppleCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;

  const _AppleCard({required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: double.infinity,
          padding: padding ?? const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: const BorderRadius.all(Radius.circular(16)),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// THIN RING PAINTER
// ─────────────────────────────────────────────
class _ThinRingPainter extends CustomPainter {
  final double progress;
  final bool isActive;
  final double pulseValue;

  const _ThinRingPainter({
    required this.progress,
    required this.isActive,
    required this.pulseValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    const startAngle = -pi / 2;        // top
    const fullSweep  = 2 * pi * 0.85;  // 306° arc (15° gap at bottom)

    // ── Track ─────────────────────────────────
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle + (2 * pi * 0.075),   // small gap symmetry
      fullSweep,
      false,
      Paint()
        ..color = Colors.white.withOpacity(0.07)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    if (progress <= 0) return;

    // ── Glow ──────────────────────────────────
    if (isActive) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle + (2 * pi * 0.075),
        fullSweep * progress,
        false,
        Paint()
          ..color = _T.accent.withOpacity(0.2 * pulseValue)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    // ── Active arc ────────────────────────────
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle + (2 * pi * 0.075),
      fullSweep * progress,
      false,
      Paint()
        ..color = isActive ? _T.accent : Colors.white.withOpacity(0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    // ── Endpoint dot ──────────────────────────
    if (isActive) {
      final endAngle =
          startAngle + (2 * pi * 0.075) + fullSweep * progress;
      final dotPos = Offset(
        center.dx + radius * cos(endAngle),
        center.dy + radius * sin(endAngle),
      );
      canvas.drawCircle(dotPos, 4,
          Paint()..color = Colors.white);
      canvas.drawCircle(
          dotPos,
          6,
          Paint()
            ..color = _T.accent.withOpacity(0.35 * pulseValue)
            ..maskFilter =
                const MaskFilter.blur(BlurStyle.normal, 4));
    }
  }

  @override
  bool shouldRepaint(_ThinRingPainter o) =>
      o.progress != progress ||
      o.isActive != isActive ||
      o.pulseValue != pulseValue;
}
