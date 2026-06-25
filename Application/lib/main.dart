import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const ArcheryApp());

class ArcheryApp extends StatelessWidget {
  const ArcheryApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0C0F12),
        appBarTheme: const AppBarTheme(iconTheme: IconThemeData(color: Colors.white)),
      ),
      home: const TrackerHome(),
    );
  }
}

class TrackerHome extends StatefulWidget {
  const TrackerHome({Key? key}) : super(key: key);

  @override
  State<TrackerHome> createState() => _TrackerHomeState();
}

enum SystemState { idle, recording, playing }

class _TrackerHomeState extends State<TrackerHome> {
  final String targetServiceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String targetCharUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  BluetoothDevice? targetDevice;
  BluetoothCharacteristic? dataCharacteristic;
  bool isConnecting = false;

  // Gyroscope Sight Coordinates (Micro-Wobbles)
  double liveX = 0;
  double liveY = 0;

  // Accelerometer Canting Angle (Gravity Alignment)
  double cantingValue = 0;

  // Calibration Baseline Offsets
  double offsetX = 0;
  double offsetY = 0;
  double offsetZ = 0; // Tracks the resting degree tilt of your bow mounting

  SystemState currentSystemState = SystemState.idle;
  List<Offset> recordedShotMemory = [];
  List<double> recordedCantMemory = []; // Records the cant history during a shot
  Timer? playbackTimer;
  int playbackIndex = 0;

  // Post-Shot Stability Score State
  double finalShotScore = 0.0;
  bool hasCalculatedScore = false;

  @override
  void initState() {
    super.initState();
    requestBluetoothPermissions();
  }

  @override
  void dispose() {
    playbackTimer?.cancel();
    super.dispose();
  }

  void requestBluetoothPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    if (statuses[Permission.bluetoothScan] == PermissionStatus.granted &&
        statuses[Permission.bluetoothConnect] == PermissionStatus.granted) {
      startScan();
    }
  }

  void startScan() async {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.advertisementData.advName == "Guacamole-Archery" ||
            r.advertisementData.advName.contains("Guacamole")) {
          setState(() { targetDevice = r.device; });
          FlutterBluePlus.stopScan();
          break;
        }
      }
    });
  }

  void connectToDevice() async {
    if (targetDevice == null) return;
    setState(() { isConnecting = true; });

    await targetDevice!.connect(mtu: null, autoConnect: false, license: License.nonprofit);
    List<BluetoothService> services = await targetDevice!.discoverServices();

    for (BluetoothService s in services) {
      if (s.uuid.toString().toLowerCase() == targetServiceUuid.toLowerCase()) {
        for (BluetoothCharacteristic c in s.characteristics) {
          if (c.uuid.toString().toLowerCase() == targetCharUuid.toLowerCase()) {
            dataCharacteristic = c;
            await c.setNotifyValue(true);
            listenToData();
          }
        }
      }
    }
    setState(() { isConnecting = false; });
  }

  // Dual-Sensor Unpacker Stream
  void listenToData() {
    dataCharacteristic?.lastValueStream.listen((value) {
      if (currentSystemState == SystemState.playing) return;

      // Verifying the expanded 12-byte payload package arrived intact
      if (value.length == 12) {
        final bytes = ByteData.sublistView(Uint8List.fromList(value));

        // 1. Unload Accelerometer Gravity Metrics (Bytes 0-5)
        int ax = bytes.getInt16(0, Endian.big);
        int ay = bytes.getInt16(2, Endian.big);
        int az = bytes.getInt16(4, Endian.big);

        // 2. Unload Gyroscope Rotational Velocities (Bytes 6-11)
        int gx = bytes.getInt16(6, Endian.big);
        int gy = bytes.getInt16(8, Endian.big);

        setState(() {
          // --- SIGHT CROSSHAIRS (Gyro Data) ---
          double targetX = gx.toDouble() - offsetX;
          double targetY = gy.toDouble() - offsetY;
          double gyroAlpha = 0.08;
          liveX = (gyroAlpha * targetX) + ((1.0 - gyroAlpha) * liveX);
          liveY = (gyroAlpha * targetY) + ((1.0 - gyroAlpha) * liveY);

          // --- SPIRIT LEVEL CANTING (Accelerometer Data) ---
          // Uses trigonometry to track static orientation against Earth's gravity vector.
          // Note: If your physical chip is mounted sideways or rotated on your riser,
          // you may need to swap 'ay' and 'az' to match your configuration.
          double rawAngleRadians = math.atan2(-az.toDouble(), ax.toDouble());
          double calculatedAngleDegrees = rawAngleRadians * (180.0 / math.pi);
          double targetCant = calculatedAngleDegrees - offsetZ;
          double cantAlpha = 0.15;
          cantingValue = (cantAlpha * targetCant) + ((1.0 - cantAlpha) * cantingValue);

          if (currentSystemState == SystemState.recording) {
            recordedShotMemory.add(Offset(liveX, liveY));
            recordedCantMemory.add(cantingValue);
          }
        });
      }
    });
  }

  // Post-Shot Score Calculator
  double calculatePostShotStability(List<Offset> shotData) {
    if (shotData.length < 15) return 100.0;

    double sumX = 0;
    double sumY = 0;
    for (var position in shotData) {
      sumX += position.dx;
      sumY += position.dy;
    }
    double meanX = sumX / shotData.length;
    double meanY = sumY / shotData.length;

    double totalDistanceVariance = 0;
    for (var position in shotData) {
      double dx = position.dx - meanX;
      double dy = position.dy - meanY;
      totalDistanceVariance += math.sqrt((dx * dx) + (dy * dy));
    }
    double averageDeviation = totalDistanceVariance / shotData.length;

    if (averageDeviation < 5.0) return 100.0; // Filter static desk noise

    double tuningDivider = 18.0;
    double rawScore = 100.0 - (averageDeviation / tuningDivider);
    return rawScore.clamp(0.0, 100.0);
  }

  // Zero-out calibration for all 3 dimensions at once
  void tareSensor() {
    setState(() {
      offsetX = liveX + offsetX;
      offsetY = liveY + offsetY;
      offsetZ = cantingValue + offsetZ; // Locks the current gravity tilt angle as absolute 0.0°
    });
  }

  void toggleRecording() {
    setState(() {
      if (currentSystemState == SystemState.idle) {
        recordedShotMemory.clear();
        recordedCantMemory.clear();
        finalShotScore = 0.0;
        hasCalculatedScore = false;
        currentSystemState = SystemState.recording;
      } else if (currentSystemState == SystemState.recording) {
        currentSystemState = SystemState.idle;
        finalShotScore = calculatePostShotStability(recordedShotMemory);
        hasCalculatedScore = true;
      }
    });
  }

  void startPlayback() {
    if (recordedShotMemory.isEmpty) return;

    playbackTimer?.cancel();
    setState(() {
      currentSystemState = SystemState.playing;
      playbackIndex = 0;
    });
    playbackTimer = Timer.periodic(const Duration(milliseconds: 5), (timer) {
      if (playbackIndex < recordedShotMemory.length) {
        setState(() {
          liveX = recordedShotMemory[playbackIndex].dx;
          liveY = recordedShotMemory[playbackIndex].dy;
          cantingValue = recordedCantMemory[playbackIndex];
          playbackIndex++;
        });
      } else {
        timer.cancel();
        setState(() { currentSystemState = SystemState.idle; });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isConnected = dataCharacteristic != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gyroscopic Archery Tracker', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 3.0, fontSize: 20)),
        centerTitle: true,
        elevation: 4,
        shadowColor: Colors.black54,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.only(bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20)),
        ),
        flexibleSpace: ClipRRect(
          borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(20), bottomRight: Radius.circular(20)),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1E1233), Color(0xFF0F2027), Color(0xFF0D2319)],
              ),
            ),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // BLE Connection Card
            Card(
              color: Colors.white10,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          targetDevice == null ? Icons.bluetooth_searching : Icons.bluetooth_connected,
                          color: targetDevice == null ? Colors.amberAccent : Colors.greenAccent,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          targetDevice == null ? "Searching for Device..." : "Sensor Online",
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: targetDevice != null ? Colors.green : Colors.grey[800],
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: targetDevice != null && !isConnecting && !isConnected ? connectToDevice : null,
                      child: Text(isConnecting ? "Pairing..." : (isConnected ? "Connected" : "Connect")),
                    )
                  ],
                ),
              ),
            ),

            // --- SPIRIT LEVEL CANTING BAR WIDGET ---
            Column(
              children: [
                const Text(
                    "BOW CANTING ALIGNMENT",
                    style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)
                ),
                const SizedBox(height: 8),
                Container(
                  width: 280,
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: Colors.white12, width: 1.5),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Center calibration hash mark line
                      Container(width: 2, height: 18, color: Colors.white24),

                      // Floating indicator fluid bubble
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 15),
                        // Maps true physical angle degrees directly to screen width coordinates.
                        // Full side lock occurs when canting exceeds 15.0 absolute degrees out of square.
                        left: (140 + (cantingValue / 15.0) * 140).clamp(8.0, 258.0),
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            // Flashes Warning Red if limb cant tilts past a 3-degree threshold
                            color: cantingValue.abs() > 3.0 ? Colors.redAccent : Colors.greenAccent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                  color: cantingValue.abs() > 3.0 ? Colors.redAccent : Colors.greenAccent,
                                  blurRadius: 6
                              )
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Target Crosshair Frame
            Center(
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: currentSystemState == SystemState.recording
                          ? Colors.redAccent.withValues(alpha: 0.5)
                          : (currentSystemState == SystemState.playing ? Colors.blueAccent.withValues(alpha: 0.5) : Colors.white12),
                      width: 3
                  ),
                ),
                child: CustomPaint(
                  size: const Size(320, 320),
                  painter: TargetPainter(
                      xOffset: liveX,
                      yOffset: liveY,
                      dotColor: currentSystemState == SystemState.playing ? Colors.blueAccent : Colors.greenAccent
                  ),
                ),
              ),
            ),

            // Live Data Telemetry / Post Shot Performance Score Board Switcher
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: hasCalculatedScore && currentSystemState == SystemState.idle
                  ? Column(
                key: const ValueKey('ScoreBoardView'),
                children: [
                  const Text("SHOT STABILITY RATING", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    finalShotScore.toStringAsFixed(1),
                    style: TextStyle(
                        color: finalShotScore >= 85.0 ? Colors.greenAccent : Colors.orangeAccent,
                        fontSize: 44,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Courier'
                    ),
                  ),
                ],
              )
                  : Row(
                key: const ValueKey('LiveTelemetryView'),
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildTelemetryDisplay("Horizontal (X)", liveX, Colors.cyanAccent),
                  _buildTelemetryDisplay("Vertical (Y)", liveY, Colors.yellowAccent),
                ],
              ),
            ),

            // Controller Action Command Deck Pad Row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: Colors.grey[800]),
                  icon: const Icon(Icons.gps_fixed),
                  onPressed: isConnected && currentSystemState == SystemState.idle ? tareSensor : null,
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: currentSystemState == SystemState.recording ? Colors.red[800] : Colors.grey[800],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                  icon: Icon(currentSystemState == SystemState.recording ? Icons.stop : Icons.fiber_manual_record, color: Colors.red),
                  label: Text(currentSystemState == SystemState.recording ? "Stop" : "Record"),
                  onPressed: isConnected && currentSystemState != SystemState.playing ? toggleRecording : null,
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: currentSystemState == SystemState.playing ? Colors.blue[800] : Colors.grey[800],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                  icon: const Icon(Icons.play_arrow, color: Colors.blueAccent),
                  label: Text(currentSystemState == SystemState.playing ? "Playing (${playbackIndex}/${recordedShotMemory.length})" : "Playback"),
                  onPressed: currentSystemState == SystemState.idle && recordedShotMemory.isNotEmpty ? startPlayback : null,
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryDisplay(String label, double value, Color metricColor) {
    return Column(
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
        const SizedBox(height: 4),
        Text(
          value.toStringAsFixed(0),
          style: TextStyle(color: metricColor, fontSize: 24, fontWeight: FontWeight.bold, fontFamily: 'Courier'),
        ),
      ],
    );
  }
}

class TargetPainter extends CustomPainter {
  final double xOffset;
  final double yOffset;
  final Color dotColor;

  TargetPainter({required this.xOffset, required this.yOffset, required this.dotColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;
    final ringPaint = Paint()..color = Colors.white24..style = PaintingStyle.stroke..strokeWidth = 1.5;

    canvas.drawCircle(center, maxRadius, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.66, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.33, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.05, Paint()..color = Colors.redAccent.withValues(alpha: 0.4));
    canvas.drawLine(Offset(10, center.dy), Offset(size.width - 10, center.dy), ringPaint);
    canvas.drawLine(Offset(center.dx, 10), Offset(center.dx, size.height - 10), ringPaint);

    double mappedX = center.dx + (xOffset / 1500.0) * maxRadius;
    double mappedY = center.dy - (yOffset / 1500.0) * maxRadius;

    Offset dotPosition = Offset(mappedX.clamp(12.0, size.width - 12.0), mappedY.clamp(12.0, size.height - 12.0));

    canvas.drawCircle(dotPosition, 7, Paint()..color = dotColor..style = PaintingStyle.fill);
    canvas.drawCircle(dotPosition, 14, Paint()..color = dotColor.withValues(alpha: 0.3)..style = PaintingStyle.stroke..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant TargetPainter oldDelegate) {
    return oldDelegate.xOffset != xOffset || oldDelegate.yOffset != yOffset || oldDelegate.dotColor != dotColor;
  }
}