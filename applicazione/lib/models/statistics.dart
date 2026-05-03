class DailyStats {
  final int steps;
  final double km;
  final int minutes;

  DailyStats({required this.steps, required this.km, required this.minutes});

  factory DailyStats.empty() => DailyStats(steps: 0, km: 0.0, minutes: 0);

  String get formattedKm => km.toStringAsFixed(1);
}
