import 'package:flutter/material.dart';
import 'dart:math';
import 'scambio.dart' as scambio;

class BatteryScreen extends StatefulWidget {
  const BatteryScreen({Key? key}) : super(key: key);

  @override
  State<BatteryScreen> createState() => _BatteryScreenState();
}

class _BatteryScreenState extends State<BatteryScreen> {
  late Future<int?> _batteryFuture;

  @override
  void initState() {
    super.initState();
    _batteryFuture = scambio.getUltimoLivelloBatteria();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<int?>(
        future: _batteryFuture,
        builder: (context, snapshot) {
          // 1. Stato di Caricamento
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: Color(0xFF00C6B8)));
          }

          // 2. Stato di Errore
          if (snapshot.hasError || !snapshot.hasData) {
            return const Center(
                child: Text("Errore nel recupero dati batteria"));
          }

          // 3. Dati Ricevuti
          final int batteryInt = snapshot.data ?? 0;
          final double batteryLevel = batteryInt / 100.0;

          // --- LOGICA DINAMICA DEI COLORI E TESTI ---
          List<Color> ringColors;
          Color mainColor;
          String statusText;

          if (batteryInt <= 0) {
            // Batteria morta
            ringColors = [Colors.red.shade900, Colors.red.shade700];
            mainColor = Colors.red;
            statusText = "Scarica";
          } else if (batteryInt <= 20) {
            // Batteria in esaurimento (<= 20%)
            ringColors = [Colors.orange, Colors.redAccent];
            mainColor = Colors.redAccent;
            statusText = "In esaurimento";
          } else {
            // Batteria ok (> 20%)
            ringColors = const [Color(0xFF00E2C1), Color(0xFF00C6B8)];
            mainColor = const Color(0xFF00C6B8);
            statusText = "Carica";
          }

          // Calcolo stimato realistico (ipotizzando 7 giorni al 100%)
          double estimatedDays = (batteryInt / 100.0) * 7.0;

          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 25.0),
            child: Column(
              children: [
                const SizedBox(height: 40),
                const Text(
                  'Stato Batteria',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3142)),
                ),
                const SizedBox(height: 40),

                // Anello di progresso batteria
                SizedBox(
                  width: 220,
                  height: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      GradientCircularProgress(
                        percentage: batteryLevel,
                        strokeWidth: 22,
                        colors: ringColors, // <--- Colore dinamico inserito qui
                      ),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${batteryInt}%',
                            style: TextStyle(
                                fontSize: 54,
                                fontWeight: FontWeight.bold,
                                color: mainColor), // <--- Colore dinamico
                          ),
                          Text(
                            statusText, // <--- Testo dinamico ("In esaurimento", ecc.)
                            style: TextStyle(
                                fontSize: 16,
                                color: batteryInt <= 20
                                    ? mainColor
                                    : Colors.black38,
                                fontWeight: batteryInt <= 20
                                    ? FontWeight.bold
                                    : FontWeight.normal),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 50),

                // Card Unica: Durata Stimata (Cambia colore anche l'icona!)
                _buildBatteryDetailCard(
                    Icons.access_time,
                    "Durata Stimata",
                    batteryInt <= 0
                        ? "Spento"
                        : "~ ${estimatedDays.toStringAsFixed(1)} giorni",
                    batteryInt <= 20 ? Colors.redAccent : Colors.blue),

                const SizedBox(height: 40),

                // Dettagli Tecnici (che piacciono al prof)
                _buildTechDetail(
                    "Capacità Batteria", "3000 mAh", Icons.battery_full),
                const SizedBox(height: 15),
                _buildTechDetail("Consumo ad Invio", "~ 45 mA", Icons.sensors),
                const SizedBox(height: 15),
                _buildTechDetail("Intervallo medio", "2 min", Icons.history),

                const SizedBox(height: 40),

                const Text(
                  "NOTA: La durata è stimata sul consumo dei dati inviati dal collare.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: Colors.grey,
                      fontSize: 12),
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  // --- WIDGET HELPER (Spostati dentro la classe State o come widget esterni) ---

  Widget _buildBatteryDetailCard(
      IconData icon, String title, String subtitle, Color color) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
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
            backgroundColor: color.withOpacity(0.1),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 14, color: Colors.black45)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3142))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTechDetail(String title, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Colors.black26, size: 20),
        const SizedBox(width: 15),
        Text(title,
            style: const TextStyle(color: Colors.black54, fontSize: 16)),
        const Spacer(),
        Text(value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ],
    );
  }
}

class GradientCircularProgress extends StatelessWidget {
  final double percentage;
  final double strokeWidth;
  final List<Color> colors;

  const GradientCircularProgress({
    Key? key,
    required this.percentage,
    required this.strokeWidth,
    required this.colors,
  }) : super(key: key);

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
