import '../objects/activities.dart';

class ActivitiesService {
  static const double strideLength = 0.3;

  /// Calcola i totali aggregati per una lista di attività
  static Map<String, dynamic> aggregateDailyStats(List<Activities> activities) {
    int totalSteps = 0;
    Duration totalDuration = Duration.zero;

    for (var act in activities) {
      totalSteps += act.totalSteps;
      
      // Calcoliamo la durata solo se l'attività è conclusa (ha un end_time)
      if (act.startTime != null && act.endTime != null) {
        totalDuration += act.endTime!.difference(act.startTime!);
      } else if (act.isActive && act.startTime != null) {
        // Se è ancora attiva, calcoliamo il tempo trascorso fino ad ora
        totalDuration += DateTime.now().difference(act.startTime!);
      }
    }

    double totalKm = (totalSteps * strideLength) / 1000;

    return {
      'steps': totalSteps,
      'km': totalKm.toStringAsFixed(1),
      'minutes': totalDuration.inMinutes,
      'count': activities.length,
    };
  }
}