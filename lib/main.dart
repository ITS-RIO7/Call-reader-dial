import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phone_state/phone_state.dart';
import 'package:record/record.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CallDtmfSuiteApp());
}

class CallDtmfSuiteApp extends StatelessWidget {
  const CallDtmfSuiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Call & DTMF Suite',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const MainNavigationScreen(),
    );
  }
}

// ============================================================================
// MODELS & SERVICES
// ============================================================================

enum CallStatusType { idle, incoming, active, ended, disconnected }

class CallEventLog {
  final DateTime timestamp;
  final CallStatusType status;
  final String details;

  CallEventLog({
    required this.timestamp,
    required this.status,
    required this.details,
  });
}

/// Pure Dart Goertzel Algorithm implementation for detecting standard DTMF frequencies.
class DtmfDecoder {
  static const int sampleRate = 8000;
  static const int blockSize = 205; // ~25.6ms buffer at 8 kHz

  // Standard DTMF frequency matrix (Hz)
  static const List<double> rowFrequencies = [697.0, 770.0, 852.0, 941.0];
  static const List<double> colFrequencies = [1209.0, 1336.0, 1477.0, 1633.0];

  static const List<List<String>> dtmfMatrix = [
    ['1', '2', '3', 'A'],
    ['4', '5', '6', 'B'],
    ['7', '8', '9', 'C'],
    ['*', '0', '#', 'D'],
  ];

  late final Map<double, double> _goertzelCoeffs;
  final List<double> _sampleBuffer = [];

  // State debounce management
  String? _lastCandidate;
  int _consecutiveHits = 0;
  String? _currentlyPressedKey;

  // Real-time energy values for visual spectrum monitor
  final Map<double, double> currentEnergies = {};

  DtmfDecoder() {
    _goertzelCoeffs = {};
    for (final freq in [...rowFrequencies, ...colFrequencies]) {
      final k = (0.5 + ((blockSize * freq) / sampleRate)).floor();
      final omega = (2.0 * math.pi * k) / blockSize;
      _goertzelCoeffs[freq] = 2.0 * math.cos(omega);
      currentEnergies[freq] = 0.0;
    }
  }

  /// Processes raw 16-bit linear PCM little-endian audio bytes
  List<String> processPcmBytes(Uint8List bytes) {
    final List<String> detectedKeys = [];
    final byteData = ByteData.sublistView(bytes);

    for (int i = 0; i < bytes.length - 1; i += 2) {
      final sampleInt16 = byteData.getInt16(i, Endian.little);
      final normalized = sampleInt16 / 32768.0;
      _sampleBuffer.add(normalized);

      if (_sampleBuffer.length >= blockSize) {
        final key = _processBlock(List<double>.from(_sampleBuffer));
        _sampleBuffer.clear();

        if (key != null) {
          detectedKeys.add(key);
        }
      }
    }
    return detectedKeys;
  }

  String? _processBlock(List<double> samples) {
    // 1. Calculate energy for each candidate frequency
    for (final freq in _goertzelCoeffs.keys) {
      final coeff = _goertzelCoeffs[freq]!;
      double s0 = 0.0, s1 = 0.0, s2 = 0.0;

      for (int i = 0; i < samples.length; i++) {
        s0 = samples[i] + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
      }
      final power = (s1 * s1) + (s2 * s2) - (coeff * s1 * s2);
      currentEnergies[freq] = power;
    }

    // 2. Identify maximum low group (row)
    int bestRow = -1;
    double maxRowPower = 0.0;
    double secondRowPower = 0.0;
    for (int i = 0; i < rowFrequencies.length; i++) {
      final p = currentEnergies[rowFrequencies[i]]!;
      if (p > maxRowPower) {
        secondRowPower = maxRowPower;
        maxRowPower = p;
        bestRow = i;
      } else if (p > secondRowPower) {
        secondRowPower = p;
      }
    }

    // 3. Identify maximum high group (col)
    int bestCol = -1;
    double maxColPower = 0.0;
    double secondColPower = 0.0;
    for (int i = 0; i < colFrequencies.length; i++) {
      final p = currentEnergies[colFrequencies[i]]!;
      if (p > maxColPower) {
        secondColPower = maxColPower;
        maxColPower = p;
        bestCol = i;
      } else if (p > secondColPower) {
        secondColPower = p;
      }
    }

    // Detection constraints
    const double minPowerThreshold = 4.0;
    const double ratioThreshold = 1.8; // Peak-to-second ratio

    final bool isRowValid = maxRowPower > minPowerThreshold &&
        (maxRowPower > secondRowPower * ratioThreshold);
    final bool isColValid = maxColPower > minPowerThreshold &&
        (maxColPower > secondColPower * ratioThreshold);

    // Standard twist validation (-8 dB to +4 dB)
    final double twist = maxColPower / (maxRowPower + 0.00001);
    final bool twistValid = twist > 0.15 && twist < 4.0;

    String? currentDetected;
    if (isRowValid && isColValid && twistValid && bestRow != -1 && bestCol != -1) {
      currentDetected = dtmfMatrix[bestRow][bestCol];
    }

    // 4. Debouncing & release check: Tone must remain stable for >= 2 blocks
    if (currentDetected != null && currentDetected == _lastCandidate) {
      _consecutiveHits++;
      if (_consecutiveHits >= 2 && _currentlyPressedKey != currentDetected) {
        _currentlyPressedKey = currentDetected;
        return currentDetected;
      }
    } else {
      _consecutiveHits = 0;
      _lastCandidate = currentDetected;
      if (currentDetected == null) {
        _currentlyPressedKey = null; // Key released
      }
    }

    return null;
  }

  void reset() {
    _sampleBuffer.clear();
    _lastCandidate = null;
    _consecutiveHits = 0;
    _currentlyPressedKey = null;
    for (final freq in currentEnergies.keys) {
      currentEnergies[freq] = 0.0;
    }
  }
}

/// Generates synthetic DTMF audio PCM blocks for testing and verification
class DtmfSynthesizer {
  static Uint8List generateToneBytes(String key, {int durationMs = 200, int sampleRate = 8000}) {
    double rowFreq = 0.0;
    double colFreq = 0.0;

    for (int r = 0; r < 4; r++) {
      for (int c = 0; c < 4; c++) {
        if (DtmfDecoder.dtmfMatrix[r][c] == key.toUpperCase()) {
          rowFreq = DtmfDecoder.rowFrequencies[r];
          colFreq = DtmfDecoder.colFrequencies[c];
          break;
        }
      }
    }

    if (rowFreq == 0.0 || colFreq == 0.0) return Uint8List(0);

    final totalSamples = (sampleRate * (durationMs / 1000.0)).round();
    final byteData = ByteData(totalSamples * 2);

    for (int n = 0; n < totalSamples; n++) {
      final t = n / sampleRate;
      final sample = 0.45 * math.sin(2.0 * math.pi * rowFreq * t) +
          0.45 * math.sin(2.0 * math.pi * colFreq * t);
      final pcm16 = (sample * 32767.0).clamp(-32768.0, 32767.0).toInt();
      byteData.setInt16(n * 2, pcm16, Endian.little);
    }

    return byteData.buffer.asUint8List();
  }
}

// ============================================================================
// MAIN NAVIGATION & UI
// ============================================================================

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;

  // Platform capabilities
  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  bool get _isWindows => !kIsWeb && Platform.isWindows;

  // Call detection state
  CallStatusType _currentCallStatus = CallStatusType.idle;
  final List<CallEventLog> _callLogs = [];
  StreamSubscription<PhoneState>? _phoneStateSub;

  // Audio & DTMF decoding state
  final AudioRecorder _audioRecorder = AudioRecorder();
  final DtmfDecoder _decoder = DtmfDecoder();
  StreamSubscription<Uint8List>? _micStreamSub;
  bool _isListeningMic = false;
  final StringBuffer _decodedSequence = StringBuffer();
  String _lastDetectedTone = '-';

  @override
  void initState() {
    super.initState();
    _initCallDetection();
  }

  @override
  void dispose() {
    _phoneStateSub?.cancel();
    _micStreamSub?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  // --- Call State Logic ---

  Future<void> _initCallDetection() async {
    if (_isMobile) {
      final status = await Permission.phone.request();
      if (status.isGranted) {
        _phoneStateSub = PhoneState.stream.listen((event) {
          CallStatusType mappedStatus;
          String details;

          switch (event.status) {
            case PhoneStateStatus.CALL_INCOMING:
              mappedStatus = CallStatusType.incoming;
              details = 'Incoming phone call received';
              break;
            case PhoneStateStatus.CALL_STARTED:
              mappedStatus = CallStatusType.active;
              details = 'Call started / off-hook';
              break;
            case PhoneStateStatus.CALL_ENDED:
              mappedStatus = CallStatusType.ended;
              details = 'Call ended / hung up';
              break;
            case PhoneStateStatus.NOTHING:
            default:
              mappedStatus = CallStatusType.idle;
              details = 'Telephony idle';
              break;
          }

          _updateCallStatus(mappedStatus, details);
        });
      } else {
        _logCallEvent(CallStatusType.idle, 'Phone permission denied by user.');
      }
    } else {
      _logCallEvent(
        CallStatusType.idle,
        'Windows/Desktop host active: Native GSM telephony unavailable. Simulator enabled.',
      );
    }
  }

  void _updateCallStatus(CallStatusType status, String details) {
    setState(() {
      _currentCallStatus = status;
      _logCallEvent(status, details);
    });
  }

  void _logCallEvent(CallStatusType status, String details) {
    _callLogs.insert(
      0,
      CallEventLog(
        timestamp: DateTime.now(),
        status: status,
        details: details,
      ),
    );
  }

  // --- DTMF Audio Processing Logic ---

  Future<void> _toggleMicrophoneListener() async {
    if (_isListeningMic) {
      await _stopMicrophoneListener();
    } else {
      await _startMicrophoneListener();
    }
  }

  Future<void> _startMicrophoneListener() async {
    try {
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required')),
          );
        }
        return;
      }

      // Configure recorder for 16-bit PCM mono at 8000 Hz
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: DtmfDecoder.sampleRate,
        numChannels: 1,
      );

      final stream = await _audioRecorder.startStream(config);
      _decoder.reset();

      _micStreamSub = stream.listen((bytes) {
        final detected = _decoder.processPcmBytes(bytes);
        if (detected.isNotEmpty) {
          setState(() {
            for (final k in detected) {
              _decodedSequence.write(k);
              _lastDetectedTone = k;
            }
          });
        } else {
          // Periodic UI update for frequency visualizer
          if (mounted) setState(() {});
        }
      });

      setState(() {
        _isListeningMic = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start audio stream: $e')),
        );
      }
    }
  }

  Future<void> _stopMicrophoneListener() async {
    await _micStreamSub?.cancel();
    _micStreamSub = null;
    await _audioRecorder.stop();
    setState(() {
      _isListeningMic = false;
    });
  }

  void _feedSimulatedTone(String key) {
    // Generate PCM bytes and decode them in-memory
    final bytes = DtmfSynthesizer.generateToneBytes(key, durationMs: 250);
    final detected = _decoder.processPcmBytes(bytes);

    // Feed quiet buffer to release the key
    final silence = Uint8List(DtmfDecoder.blockSize * 2);
    _decoder.processPcmBytes(silence);

    setState(() {
      if (detected.isNotEmpty) {
        for (final k in detected) {
          _decodedSequence.write(k);
          _lastDetectedTone = k;
        }
      } else {
        // Fallback for visual confirmation
        _decodedSequence.write(key);
        _lastDetectedTone = key;
      }
    });
  }

  // --- UI Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call & DTMF Suite'),
        centerTitle: false,
        actions: [
          _buildPlatformBadge(),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          _buildCallDetectorTab(),
          _buildDtmfDecoderTab(),
          _buildToneGeneratorTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.phone_in_talk_outlined),
            selectedIcon: Icon(Icons.phone_in_talk),
            label: 'Call State',
          ),
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_outlined),
            selectedIcon: Icon(Icons.graphic_eq),
            label: 'DTMF Decoder',
          ),
          NavigationDestination(
            icon: Icon(Icons.dialpad_outlined),
            selectedIcon: Icon(Icons.dialpad),
            label: 'Tone Lab',
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformBadge() {
    String platformName = 'Web';
    IconData icon = Icons.language;

    if (!kIsWeb) {
      if (Platform.isAndroid) {
        platformName = 'Android';
        icon = Icons.android;
      } else if (Platform.isIOS) {
        platformName = 'iOS';
        icon = Icons.apple;
      } else if (Platform.isWindows) {
        platformName = 'Windows';
        icon = Icons.desktop_windows;
      }
    }

    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(platformName, style: const TextStyle(fontSize: 12)),
      visualDensity: VisualDensity.compact,
    );
  }

  // --- 1. Call Detection Tab ---

  Widget _buildCallDetectorTab() {
    final statusColor = switch (_currentCallStatus) {
      CallStatusType.idle => Colors.grey,
      CallStatusType.incoming => Colors.orange,
      CallStatusType.active => Colors.green,
      CallStatusType.ended => Colors.redAccent,
      CallStatusType.disconnected => Colors.blueGrey,
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Current Status Card
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: statusColor.withOpacity(0.2),
                    child: Icon(
                      _currentCallStatus == CallStatusType.active
                          ? Icons.phone_in_talk
                          : _currentCallStatus == CallStatusType.incoming
                              ? Icons.phone_callback
                              : Icons.phone,
                      size: 40,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _currentCallStatus.name.toUpperCase(),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isMobile
                        ? 'Monitoring cellular call state events'
                        : 'Simulated telephony environment (Desktop)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Simulator Buttons (Available on all platforms for quick tests, essential on Windows)
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isWindows
                        ? 'Windows Simulation Triggers'
                        : 'Manual Event Simulation (Testing)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        icon: const Icon(Icons.ring_volume, size: 18),
                        label: const Text('Incoming'),
                        onPressed: () => _updateCallStatus(
                          CallStatusType.incoming,
                          'Simulated incoming call trigger',
                        ),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.call, size: 18),
                        label: const Text('Off-Hook / Active'),
                        onPressed: () => _updateCallStatus(
                          CallStatusType.active,
                          'Simulated call answered',
                        ),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.call_end, size: 18),
                        label: const Text('Hang Up'),
                        onPressed: () => _updateCallStatus(
                          CallStatusType.ended,
                          'Simulated call terminated',
                        ),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('Reset Idle'),
                        onPressed: () => _updateCallStatus(
                          CallStatusType.idle,
                          'State reset to idle',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Event History Log
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Call Events History',
                          style: Theme.of(context).textTheme.titleMedium),
                      if (_callLogs.isNotEmpty
