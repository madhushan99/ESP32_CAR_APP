import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  WakelockPlus.enable();
  runApp(const RCCarApp());
}

class RCCarApp extends StatelessWidget {
  const RCCarApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RC Car Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0C),
      ),
      home: const RCCarController(),
    );
  }
}

class RCCarController extends StatefulWidget {
  const RCCarController({super.key});
  @override
  State<RCCarController> createState() => _RCCarControllerState();
}

class _RCCarControllerState extends State<RCCarController> {
  static const Color kRed = Color(0xFFE8001C);
  static const Color kBg = Color(0xFF0A0A0C);
  static const Color kBg2 = Color(0xFF111116);
  static const Color kBg3 = Color(0xFF18181F);
  static const Color kGreen = Color(0xFF00E676);
  static const Color kMuted = Color(0xFF6A6A7A);
  static const Color kText = Color(0xFFF0F0F4);

  // MQTT
  MqttServerClient? _client;
  bool _isConnected = false;
  final _serverCtrl = TextEditingController(
      text: 'b1af481d3e2a4ec4b90301e5f0d2ad8c.s1.eu.hivemq.cloud');
  final _portCtrl = TextEditingController(text: '8883');
  final _userCtrl = TextEditingController(text: 'madushan7');
  final _passCtrl = TextEditingController(text: 'Abcdefgh12345678');
  final _topicCtrl = TextEditingController(text: 'car/control');
  String _ctrlTopic = 'car/control';
  String _fbTopic = 'car/feedback';

  // Heartbeat
  Timer? _hbTimer;
  bool _hbActive = false;

  // Gear & OA
  int _gear = 1;
  bool _oaOn = false;

  // Console
  final List<_LogEntry> _logs = [];
  final ScrollController _scrollCtrl = ScrollController();
  bool _showConsole = false;

  // D-Pad state
  bool _pressingF = false;
  bool _pressingB = false;
  bool _pressingL = false;
  bool _pressingR = false;

  // UI
  bool _showConnPanel = false;

  // Camera
  WebViewController? _webViewController;
  final _camUrlCtrl =
      TextEditingController(text: 'https://vdo.ninja/?view=zAhSpQw');
  bool _camLoaded = false;

  @override
  void dispose() {
    _stopHeartbeat();
    _client?.disconnect();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _log(String msg, {LogType type = LogType.info}) {
    setState(() {
      _logs.add(_LogEntry(msg, type, DateTime.now()));
      if (_logs.length > 60) _logs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _hbTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _sendCmd('HB', silent: true);
    });
    setState(() => _hbActive = true);
    _log('Heartbeat started', type: LogType.success);
  }

  void _stopHeartbeat() {
    _hbTimer?.cancel();
    _hbTimer = null;
    setState(() => _hbActive = false);
  }

  Future<void> _connect() async {
    final server = _serverCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 8883;
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    _ctrlTopic =
        _topicCtrl.text.trim().isEmpty ? 'car/control' : _topicCtrl.text.trim();
    _fbTopic = _ctrlTopic.replaceAll('control', 'feedback');
    if (server.isEmpty || user.isEmpty || pass.isEmpty) {
      _log('Fill all fields', type: LogType.error);
      return;
    }
    _log('Connecting...');
    final clientId = 'flutter_${DateTime.now().millisecondsSinceEpoch}';
    _client = MqttServerClient.withPort(server, clientId, port);
    _client!.secure = true;
    _client!.keepAlivePeriod = 20;
    _client!.onDisconnected = _onDisconnected;
    _client!.onConnected = _onConnected;
    _client!.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(user, pass)
        .startClean();
    try {
      await _client!.connect();
    } catch (e) {
      _log('Error: $e', type: LogType.error);
      _client?.disconnect();
      setState(() => _isConnected = false);
    }
  }

  void _onConnected() {
    setState(() {
      _isConnected = true;
      _showConnPanel = false;
    });
    _log('Connected!', type: LogType.success);
    _client!.subscribe(_fbTopic, MqttQos.atMostOnce);
    _client!.updates!.listen((msgs) {
      final payload = MqttPublishPayload.bytesToStringAsString(
          (msgs[0].payload as MqttPublishMessage).payload.message);
      _log('ESP32: $payload', type: LogType.success);
    });
    _startHeartbeat();
  }

  void _onDisconnected() {
    _stopHeartbeat();
    setState(() => _isConnected = false);
    _log('Disconnected!', type: LogType.warn);
  }

  void _disconnect() {
    _stopHeartbeat();
    _client?.disconnect();
    setState(() {
      _isConnected = false;
      _gear = 1;
      _oaOn = false;
    });
    _log('Disconnected', type: LogType.info);
  }

  void _sendCmd(String cmd, {bool silent = false}) {
    if (!_isConnected || _client == null) {
      if (!silent) _log('Not connected', type: LogType.error);
      return;
    }
    final builder = MqttClientPayloadBuilder()..addString(cmd);
    _client!.publishMessage(_ctrlTopic, MqttQos.atMostOnce, builder.payload!);
    if (!silent) _log('CMD: $cmd');
  }

  void _press(String dir) {
    _sendCmd(dir);
    setState(() {
      if (dir == 'F') _pressingF = true;
      if (dir == 'B') _pressingB = true;
      if (dir == 'L') _pressingL = true;
      if (dir == 'R') _pressingR = true;
    });
  }

  void _release(String dir) {
    final stopMap = {'F': 'SF', 'B': 'SB', 'L': 'SL', 'R': 'SR'};
    _sendCmd(stopMap[dir]!);
    setState(() {
      if (dir == 'F') _pressingF = false;
      if (dir == 'B') _pressingB = false;
      if (dir == 'L') _pressingL = false;
      if (dir == 'R') _pressingR = false;
    });
  }

  void _changeGear(int g) {
    if (!_isConnected) return;
    _sendCmd(g.toString());
    setState(() => _gear = g);
    _log('Gear: $g', type: LogType.success);
  }

  void _toggleOA() {
    if (!_isConnected) {
      _log('Connect first', type: LogType.error);
      return;
    }
    setState(() => _oaOn = !_oaOn);
    _sendCmd(_oaOn ? 'OA_ON' : 'OA_OFF');
    _log('OA: ${_oaOn ? "ON" : "OFF"}',
        type: _oaOn ? LogType.success : LogType.info);
  }

  void _loadCamera() {
    String url = _camUrlCtrl.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http')) url = 'https://vdo.ninja/?view=$url';
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..loadRequest(Uri.parse(url));
    setState(() {
      _webViewController = controller;
      _camLoaded = true;
    });
    _log('Camera: $url', type: LogType.success);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            if (_showConnPanel) _buildConnPanel(),
            Expanded(
              child: Row(
                children: [
                  // ── LEFT: Forward / Backward ──
                  SizedBox(width: 110, child: _buildDrivePanel()),
                  // ── CENTER: Camera + overlays ──
                  Expanded(child: _buildCenterPanel()),
                  // ── RIGHT: Steer Left / Right ──
                  SizedBox(width: 110, child: _buildSteerPanel()),
                ],
              ),
            ),
            if (_showConsole) _buildConsoleBar(),
          ],
        ),
      ),
    );
  }

  // ── TOP BAR ──────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: kBg2,
      child: Row(
        children: [
          // Logo
          RichText(
              text: const TextSpan(
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 3),
            children: [
              TextSpan(text: 'RC/', style: TextStyle(color: kRed)),
              TextSpan(text: 'CMD', style: TextStyle(color: kText)),
            ],
          )),
          const SizedBox(width: 10),

          // Status dot
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isConnected ? kGreen : kMuted,
                  boxShadow: _isConnected
                      ? [BoxShadow(color: kGreen, blurRadius: 5)]
                      : null)),
          const SizedBox(width: 5),
          Text(_isConnected ? 'ONLINE' : 'OFFLINE',
              style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1,
                  color: _isConnected ? kGreen : kMuted)),
          const SizedBox(width: 8),

          // HB
          _pill(
              _hbActive ? 'HB: ON' : 'HB: OFF',
              _hbActive ? kGreen.withOpacity(0.3) : Colors.transparent,
              _hbActive ? kGreen : kMuted),
          const SizedBox(width: 6),

          // Gear selector inline
          ...List.generate(4, (i) {
            final g = i + 1;
            final active = _gear == g;
            return GestureDetector(
              onTap: () => _changeGear(g),
              child: Container(
                width: 28,
                height: 24,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  color: active ? kRed : kBg3,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                      color: active ? kRed : Colors.white.withOpacity(0.07)),
                ),
                child: Center(
                    child: Text('$g',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: active ? Colors.white : kMuted))),
              ),
            );
          }),
          const SizedBox(width: 8),

          // OA toggle
          GestureDetector(
            onTap: _toggleOA,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _oaOn ? kGreen.withOpacity(0.15) : kBg3,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                    color: _oaOn ? kGreen : Colors.white.withOpacity(0.07)),
              ),
              child: Row(children: [
                Text('AVOID',
                    style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 1,
                        color: _oaOn ? kGreen : kMuted)),
                const SizedBox(width: 5),
                _buildToggle(_oaOn, small: true),
              ]),
            ),
          ),
          const SizedBox(width: 6),

          // Console toggle
          GestureDetector(
            onTap: () => setState(() => _showConsole = !_showConsole),
            child: _pill(
                'LOG',
                _showConsole ? kRed.withOpacity(0.2) : Colors.transparent,
                _showConsole ? kRed : kMuted),
          ),

          const Spacer(),

          // Camera URL input
          SizedBox(
            width: 200,
            height: 26,
            child: TextField(
              controller: _camUrlCtrl,
              style: const TextStyle(
                  fontSize: 10, fontFamily: 'monospace', color: kText),
              decoration: InputDecoration(
                hintText: 'vdo.ninja URL',
                hintStyle: const TextStyle(color: kMuted, fontSize: 10),
                filled: true,
                fillColor: kBg3,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(3),
                    borderSide:
                        BorderSide(color: Colors.white.withOpacity(0.07))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(3),
                    borderSide:
                        BorderSide(color: Colors.white.withOpacity(0.07))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(3),
                    borderSide: const BorderSide(color: kRed)),
              ),
            ),
          ),
          const SizedBox(width: 5),
          _smallBtn('LOAD', kRed, _loadCamera),
          const SizedBox(width: 8),

          // Connect / Disconnect
          if (!_isConnected)
            _smallBtn('CONNECT', kRed,
                () => setState(() => _showConnPanel = !_showConnPanel))
          else
            _smallBtn('DISCONNECT', kMuted, _disconnect),
        ],
      ),
    );
  }

  Widget _pill(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: fg.withOpacity(0.3))),
      child: Text(text,
          style: TextStyle(fontSize: 9, letterSpacing: 1, color: fg)),
    );
  }

  Widget _smallBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: color == kRed ? kRed : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: color != kRed ? Border.all(color: kMuted) : null,
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: color == kRed ? Colors.white : kMuted)),
      ),
    );
  }

  // ── CONNECTION PANEL ─────────────────────────────────────
  Widget _buildConnPanel() {
    return Container(
      padding: const EdgeInsets.all(8),
      color: kBg2,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _connField(_serverCtrl, 'MQTT Server', 190),
          _connField(_portCtrl, 'Port', 65, keyboardType: TextInputType.number),
          _connField(_userCtrl, 'Username', 105),
          _connField(_passCtrl, 'Password', 105, obscure: true),
          _connField(_topicCtrl, 'Topic', 105),
          GestureDetector(
            onTap: _connect,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                  color: kRed, borderRadius: BorderRadius.circular(3)),
              child: const Text('CONNECT',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                      color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _connField(TextEditingController ctrl, String hint, double width,
      {bool obscure = false, TextInputType? keyboardType}) {
    return SizedBox(
      width: width,
      height: 30,
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboardType,
        style: const TextStyle(
            fontSize: 11, fontFamily: 'monospace', color: kText),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: kMuted, fontSize: 11),
          filled: true,
          fillColor: kBg3,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(3),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.07))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(3),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.07))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(3),
              borderSide: const BorderSide(color: kRed)),
        ),
      ),
    );
  }

  // ── LEFT: DRIVE PANEL (FWD / BWD) ────────────────────────
  Widget _buildDrivePanel() {
    return Container(
      margin: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('DRIVE',
              style: TextStyle(fontSize: 8, letterSpacing: 2, color: kMuted)),
          const SizedBox(height: 10),
          // FORWARD — big button
          _bigDriveBtn(
            arrow: '↑',
            label: 'FWD',
            pressing: _pressingF,
            color: kRed,
            onDown: () => _press('F'),
            onUp: () => _release('F'),
          ),
          const SizedBox(height: 8),
          // STOP
          GestureDetector(
            onTap: () => _sendCmd('S'),
            child: Container(
              width: double.infinity,
              height: 44,
              decoration: BoxDecoration(
                color: kBg3,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('■',
                        style:
                            TextStyle(fontSize: 14, color: Color(0xFFFF8C00))),
                    Text('STOP',
                        style: TextStyle(
                            fontSize: 8,
                            letterSpacing: 1,
                            color: Color(0xFFFF8C00))),
                  ]),
            ),
          ),
          const SizedBox(height: 8),
          // BACKWARD — big button
          _bigDriveBtn(
            arrow: '↓',
            label: 'BWD',
            pressing: _pressingB,
            color: const Color(0xFF1565C0),
            onDown: () => _press('B'),
            onUp: () => _release('B'),
          ),
        ],
      ),
    );
  }

  Widget _bigDriveBtn({
    required String arrow,
    required String label,
    required bool pressing,
    required Color color,
    required VoidCallback onDown,
    required VoidCallback onUp,
  }) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => _isConnected ? onDown() : null,
        onTapUp: (_) => _isConnected ? onUp() : null,
        onTapCancel: () => _isConnected ? onUp() : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: double.infinity,
          decoration: BoxDecoration(
            color: pressing ? color : kBg3,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: pressing ? color : Colors.white.withOpacity(0.08)),
            boxShadow: pressing
                ? [BoxShadow(color: color.withOpacity(0.4), blurRadius: 12)]
                : [],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(arrow,
                style: TextStyle(
                    fontSize: 28, color: pressing ? Colors.white : kMuted)),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: pressing ? Colors.white : kMuted)),
          ]),
        ),
      ),
    );
  }

  // ── CENTER: CAMERA ────────────────────────────────────────
  Widget _buildCenterPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _camLoaded && _webViewController != null
            ? WebViewWidget(controller: _webViewController!)
            : Center(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.videocam_outlined, size: 40, color: kMuted),
                      const SizedBox(height: 8),
                      Text('Enter vdo.ninja URL in the top bar',
                          style: TextStyle(
                              fontSize: 11, color: kMuted, letterSpacing: 1)),
                      const SizedBox(height: 4),
                      Text('then tap LOAD',
                          style: TextStyle(
                              fontSize: 10, color: kMuted.withOpacity(0.6))),
                    ]),
              ),
      ),
    );
  }

  // ── RIGHT: STEER PANEL (LEFT / RIGHT) ────────────────────
  Widget _buildSteerPanel() {
    return Container(
      margin: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('STEER',
              style: TextStyle(fontSize: 8, letterSpacing: 2, color: kMuted)),
          const SizedBox(height: 10),
          // LEFT turn
          _bigSteerBtn(
            arrow: '←',
            label: 'LEFT',
            pressing: _pressingL,
            onDown: () => _press('L'),
            onUp: () => _release('L'),
          ),
          const SizedBox(height: 8),
          // Gear indicator
          Container(
            width: double.infinity,
            height: 44,
            decoration: BoxDecoration(
              color: kBg3,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white.withOpacity(0.07)),
            ),
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('$_gear',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: kRed,
                      height: 1)),
              Text('GEAR',
                  style:
                      TextStyle(fontSize: 8, color: kMuted, letterSpacing: 1)),
            ]),
          ),
          const SizedBox(height: 8),
          // RIGHT turn
          _bigSteerBtn(
            arrow: '→',
            label: 'RIGHT',
            pressing: _pressingR,
            onDown: () => _press('R'),
            onUp: () => _release('R'),
          ),
        ],
      ),
    );
  }

  Widget _bigSteerBtn({
    required String arrow,
    required String label,
    required bool pressing,
    required VoidCallback onDown,
    required VoidCallback onUp,
  }) {
    return Expanded(
      child: GestureDetector(
        onTapDown: (_) => _isConnected ? onDown() : null,
        onTapUp: (_) => _isConnected ? onUp() : null,
        onTapCancel: () => _isConnected ? onUp() : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: double.infinity,
          decoration: BoxDecoration(
            color: pressing ? const Color(0xFF1B5E20) : kBg3,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: pressing ? kGreen : Colors.white.withOpacity(0.08)),
            boxShadow: pressing
                ? [BoxShadow(color: kGreen.withOpacity(0.3), blurRadius: 12)]
                : [],
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(arrow,
                style:
                    TextStyle(fontSize: 28, color: pressing ? kGreen : kMuted)),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: pressing ? kGreen : kMuted)),
          ]),
        ),
      ),
    );
  }

  // ── CONSOLE BAR ──────────────────────────────────────────
  Widget _buildConsoleBar() {
    return Container(
      height: 100,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF05050A),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.07))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('▶ ESP32 Console',
            style: TextStyle(
                fontSize: 9,
                letterSpacing: 2,
                color: kGreen,
                fontFamily: 'monospace')),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            itemCount: _logs.length,
            itemBuilder: (_, i) {
              final log = _logs[i];
              final t = '${log.time.hour.toString().padLeft(2, '0')}:'
                  '${log.time.minute.toString().padLeft(2, '0')}:'
                  '${log.time.second.toString().padLeft(2, '0')}';
              return Text(
                '[$t] ${log.msg}',
                style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: switch (log.type) {
                      LogType.success => kGreen,
                      LogType.error => const Color(0xFFFF5252),
                      LogType.warn => const Color(0xFFFFAB40),
                      LogType.info => const Color(0xFF448AFF),
                    }),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _buildToggle(bool on, {bool small = false}) {
    final w = small ? 28.0 : 36.0;
    final h = small ? 14.0 : 18.0;
    final k = small ? 8.0 : 12.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: w,
      height: h,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: on ? kGreen : kBg3,
        borderRadius: BorderRadius.circular(h / 2),
        border: Border.all(color: on ? kGreen : Colors.white.withOpacity(0.1)),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
            width: k,
            height: k,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Colors.white)),
      ),
    );
  }
}

enum LogType { info, success, error, warn }

class _LogEntry {
  final String msg;
  final LogType type;
  final DateTime time;
  _LogEntry(this.msg, this.type, this.time);
}
