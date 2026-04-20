import 'package:flutter/material.dart';
import 'dart:math';
import 'dart:async';
import 'scambio.dart' as scambio;
import "repositories/battery_data_repo.dart";

class BatteryScreen extends StatefulWidget {
  const BatteryScreen({super.key});

  @override
  State<BatteryScreen> createState() => _BatteryScreenState();
}

// 1. Aggiunto SingleTickerProviderStateMixin per le animazioni
class _BatteryScreenState extends State<BatteryScreen>
    with SingleTickerProviderStateMixin {
  // Riferimento al Repository per la gestione dati
  final BatteryRepository _batteryRepo = BatteryRepository(); //

  int? _currentBattery; //
  bool _isCharging = false; //
  bool _isLoading = true; //
  StreamSubscription? _streamSubscription; //

  late AnimationController _spinController; //

  @override
  void initState() {
    super.initState();

    // 1. Inizializzazione del controller per la rotazione (2 secondi per giro)
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    // 2. Avvio dell'ascolto in tempo reale tramite il Repository
    _batteryRepo.subscribeToBatteryUpdates();

    // 3. Sottoscrizione allo stream tipizzato di BatteryData
    _streamSubscription = _batteryRepo.batteryStream.listen((data) {
      debugPrint('🔋 [BATTERY SCREEN] Update ricevuto: ${data.batteryPercent}%');

      if (mounted) {
        setState(() {
          _isCharging = data.charging; //

          if (_isCharging) {
            _spinController.repeat(); //
          } else {
            _spinController.stop(); //
            _spinController.reset(); //
            _currentBattery = data.batteryPercent; //
          }

          _isLoading = false;
        });
      }
    });

    // 4. Caricamento del dato iniziale al boot della schermata
    _caricaDatiIniziali();
  }

  /// Recupera l'ultimo stato noto della batteria dal database
  Future<void> _caricaDatiIniziali() async {
    final data = await _batteryRepo.getLatestBattery(); //

    if (mounted && data != null) {
      setState(() {
        _isCharging = data.charging; //
        _currentBattery = data.batteryPercent; //
        _isLoading = false;

        if (_isCharging) {
          _spinController.repeat(); //
        }
      });
    } else if (mounted && data == null) {
      // Gestione caso in cui il DB sia vuoto o irraggiungibile
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel(); //
    _spinController.dispose(); //
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00C6B8)),
      );
    }

    if (!_isCharging && _currentBattery == null) {
      return const Center(child: Text("Errore nel recupero dati batteria"));
    }

    double batteryLevel = 0.0;
    List<Color> ringColors;
    Color mainColor;
    String statusText;
    Widget centerWidget;
    double estimatedDays = 0.0;

    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.7, 1.2);

    if (_isCharging) {
      // VISUALIZZAZIONE "IN CARICA"
      batteryLevel = 1.0;
      ringColors = const [Colors.green, Colors.greenAccent, Colors.green];

      mainColor = Colors.green;
      statusText = "In Ricarica";
      centerWidget = Icon(Icons.bolt, size: 60 * scale, color: mainColor);
      estimatedDays = 0.0;
    } else {
      // VISUALIZZAZIONE NORMALE BATTERIA
      final int batteryInt = _currentBattery!;
      batteryLevel = batteryInt / 100.0;
      estimatedDays = (batteryInt / 100.0) * 7.0;

      if (batteryInt <= 0) {
        ringColors = [Colors.red.shade900, Colors.red.shade700];
        mainColor = Colors.red;
        statusText = "Scarica";
      } else if (batteryInt <= 20) {
        ringColors = [Colors.orange, Colors.redAccent];
        mainColor = Colors.redAccent;
        statusText = "In esaurimento";
      } else {
        ringColors = const [Color(0xFF00E2C1), Color(0xFF00C6B8)];
        mainColor = const Color(0xFF00C6B8);
        statusText = "In uso";
      }

      centerWidget = Text(
        '$batteryInt%',
        style: TextStyle(
          fontSize: 50 * scale,
          fontWeight: FontWeight.bold,
          color: mainColor,
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 25.0 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(height: 20 * scale),
          Text(
            'Stato Batteria',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 26 * scale,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF2D3142),
            ),
          ),
          const Spacer(flex: 2),
          Center(
            child: SizedBox(
              width: 200 * scale,
              height: 200 * scale,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 4. Aggiunto RotationTransition attorno al cerchio per farlo girare
                  RotationTransition(
                    turns: _isCharging
                        ? _spinController
                        : const AlwaysStoppedAnimation(
                            0), // Se non carica, sta fermo a 0
                    child: GradientCircularProgress(
                      percentage: batteryLevel,
                      strokeWidth: 18 * scale,
                      colors: ringColors,
                    ),
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      centerWidget,
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 12 * scale,
                          color: (!_isCharging && _currentBattery! <= 20)
                              ? mainColor
                              : Colors.black38,
                          fontWeight: (!_isCharging && _currentBattery! <= 20)
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(flex: 2),
          _buildBatteryDetailCard(
            Icons.access_time,
            "Durata Stimata",
            _isCharging
                ? "Dispositivo in ricarica"
                : (_currentBattery! <= 0
                    ? "Dispositivo spento"
                    : "~ ${estimatedDays.toStringAsFixed(1)} giorni"),
            _isCharging
                ? Colors.green
                : ((_currentBattery ?? 100) <= 20
                    ? Colors.redAccent
                    : Colors.blue),
            scale,
          ),
          const Spacer(flex: 2),
          _buildTechDetail(
              "Capacità Batteria", "3000 mAh", Icons.battery_full, scale),
          SizedBox(height: 15 * scale),
          _buildTechDetail(
              "Consumo ad Invio", "~ 120 mA", Icons.sensors, scale),
          SizedBox(height: 15 * scale),
          _buildTechDetail("Intervallo medio", "1 min", Icons.history, scale),
          const Spacer(flex: 2),
          Center(
            child: Text(
              "Nota Bene: Stima basata sui dati inviati dal dispositivo",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: Colors.grey,
                fontSize: 10.5 * scale,
              ),
            ),
          ),
          SizedBox(height: 15 * scale),
        ],
      ),
    );
  }

  Widget _buildBatteryDetailCard(
      IconData icon, String title, String subtitle, Color color, double scale) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 16 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22 * scale),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 15,
              offset: const Offset(0, 5))
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24 * scale,
            backgroundColor: color.withOpacity(0.1),
            child: Icon(icon, color: color, size: 24 * scale),
          ),
          SizedBox(width: 20 * scale),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title,
                  style:
                      TextStyle(fontSize: 14 * scale, color: Colors.black45)),
              SizedBox(height: 4 * scale),
              Text(subtitle,
                  style: TextStyle(
                      fontSize: 18 * scale,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF2D3142))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTechDetail(
      String title, String value, IconData icon, double scale) {
    return Row(
      children: [
        Icon(icon, color: Colors.black26, size: 22 * scale),
        SizedBox(width: 15 * scale),
        Text(title,
            style: TextStyle(color: Colors.black54, fontSize: 16 * scale)),
        const Spacer(),
        Text(value,
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * scale)),
      ],
    );
  }
}

class GradientCircularProgress extends StatelessWidget {
  final double percentage;
  final double strokeWidth;
  final List<Color> colors;

  const GradientCircularProgress({
    super.key,
    required this.percentage,
    required this.strokeWidth,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GradientCircularProgressPainter(
        percentage: percentage,
        strokeWidth: strokeWidth,
        colors: colors,
      ),
      child: Container(),
    );
  }
}

class _GradientCircularProgressPainter extends CustomPainter {
  final double percentage;
  final double strokeWidth;
  final List<Color> colors;

  _GradientCircularProgressPainter({
    required this.percentage,
    required this.strokeWidth,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    double radius = (size.width / 2) - (strokeWidth / 2);
    Offset center = Offset(size.width / 2, size.height / 2);
    Rect rect = Rect.fromCircle(center: center, radius: radius);

    Paint backgroundPaint = Paint()
      ..color = const Color(0xFFE5E5EA)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawArc(rect, 0, pi * 2, false, backgroundPaint);

    if (percentage > 0) {
      Paint progressPaint = Paint()
        ..shader = SweepGradient(
          colors: colors,
          startAngle: -pi / 2,
          endAngle: 3 * pi / 2,
        ).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeWidth;

      canvas.drawArc(rect, -pi / 2, pi * 2 * percentage, false, progressPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GradientCircularProgressPainter oldDelegate) {
    return oldDelegate.percentage != percentage ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.colors != colors;
  }
}
