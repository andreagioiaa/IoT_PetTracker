import 'package:flutter/material.dart';
import 'dart:math';
import 'dart:async';
import 'scambio.dart' as scambio;

class BatteryScreen extends StatefulWidget {
  const BatteryScreen({super.key});

  @override
  State<BatteryScreen> createState() => _BatteryScreenState();
}

class _BatteryScreenState extends State<BatteryScreen> {
  int? _currentBattery;
  bool _isLoading = true;
  StreamSubscription? _streamSubscription;

  @override
  void initState() {
    super.initState();

    _streamSubscription = scambio.posizioneStream.listen((nuovoRecord) {
      debugPrint('🔊 [BATTERY SCREEN] Leggo il pacchetto...');

      try {
        final nuovaBatteria = nuovoRecord.getIntValue('battery');
        debugPrint(
            '🔋 [BATTERY SCREEN] Nuova batteria in diretta: $nuovaBatteria%');

        if (mounted) {
          setState(() {
            _currentBattery = nuovaBatteria;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint('❌ [BATTERY SCREEN] Errore lettura pacchetto: $e');
      }
    });

    _scaricaDatoIniziale();
  }

  Future<void> _scaricaDatoIniziale() async {
    final batteriaIniziale = await scambio.getUltimoLivelloBatteria();
    if (mounted && _currentBattery == null) {
      setState(() {
        _currentBattery = batteriaIniziale;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
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
          child: CircularProgressIndicator(color: Color(0xFF00C6B8)));
    }

    if (_currentBattery == null) {
      return const Center(child: Text("Errore nel recupero dati batteria"));
    }

    final int batteryInt = _currentBattery!;
    final double batteryLevel = batteryInt / 100.0;

    List<Color> ringColors;
    Color mainColor;
    String statusText;

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
      statusText = "Carica";
    }

    double estimatedDays = (batteryInt / 100.0) * 7.0;

    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.7, 1.2);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 25.0 * scale),
      child: Column(
        // Cambiato in center per allineare tutto al centro
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(height: 20 * scale),

          // 1. Titolo Centrato
          Text(
            'Stato Batteria',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 26 * scale, // Leggermente più piccolo per eleganza
                fontWeight: FontWeight.bold,
                color: const Color(0xFF2D3142)),
          ),

          const Spacer(flex: 2),

          // 2. Anello di progresso batteria RIDOTTO
          Center(
            child: SizedBox(
              width: 200 * scale, // Ridotto da 240 a 200
              height: 200 * scale, // Ridotto da 240 a 200
              child: Stack(
                alignment: Alignment.center,
                children: [
                  GradientCircularProgress(
                    percentage: batteryLevel,
                    strokeWidth: 18 * scale, // Ridotto spessore
                    colors: ringColors,
                  ),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$batteryInt%',
                        style: TextStyle(
                            fontSize: 50 * scale, // Ridotto da 60 a 50
                            fontWeight: FontWeight.bold,
                            color: mainColor),
                      ),
                      Text(
                        statusText,
                        style: TextStyle(
                            fontSize: 16 * scale,
                            color:
                                batteryInt <= 20 ? mainColor : Colors.black38,
                            fontWeight: batteryInt <= 20
                                ? FontWeight.bold
                                : FontWeight.normal),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const Spacer(flex: 2),

          // 3. Card Durata Stimata
          _buildBatteryDetailCard(
              Icons.access_time,
              "Durata Stimata",
              batteryInt <= 0
                  ? "Spento"
                  : "~ ${estimatedDays.toStringAsFixed(1)} giorni",
              batteryInt <= 20 ? Colors.redAccent : Colors.blue,
              scale),

          const Spacer(flex: 2),

          // 4. Dettagli Tecnici
          _buildTechDetail(
              "Capacità Batteria", "3000 mAh", Icons.battery_full, scale),
          SizedBox(height: 15 * scale),
          _buildTechDetail("Consumo ad Invio", "~ ? mA", Icons.sensors, scale),
          SizedBox(height: 15 * scale),
          _buildTechDetail("Intervallo medio", "1 min", Icons.history, scale),

          const Spacer(flex: 2),

          // 5. Nota a piè di pagina abbreviata e rimpicciolita
          Center(
            child: Text(
              "Nota Bene: Stima basata sui dati inviati dal dispositivo",
              maxLines: 1, // Forza una riga sola
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.grey,
                  fontSize: 10.5 * scale), // Ridotto da 12 a 10.5
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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
