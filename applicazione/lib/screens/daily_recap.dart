import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../repositories/activities_repo.dart';
import '../services/authentication.dart' as scambio;
import '../repositories/users_repo.dart';
import '../models/activities.dart';
import 'activity_details.dart';

class RecapScreen extends StatefulWidget {
  final DateTime dataSelezionata;
  const RecapScreen({super.key, required this.dataSelezionata});

  @override
  State<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends State<RecapScreen> {
  final ActivitiesRepository _activitiesRepo = ActivitiesRepository(scambio.pb);
  final UsersRepository _usersRepo = UsersRepository();

  bool _isLoading = true;
  List<Activities> _listaAttivita = [];
  
  // Mappa per salvare i nomi delle zone calcolate. Chiave = activity.id, Valore = Nome Zona
  final Map<String, String> _nomiZoneCalcolate = {};

  @override
  void initState() {
    super.initState();
    _caricaAttivitaGiornaliere();
  }

  Future<void> _caricaAttivitaGiornaliere() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      String? boardId = await _usersRepo.getBoardIdFromBoards();

      if (boardId == null || boardId.isEmpty) {
        debugPrint("⚠️[daily_recap]: Board ID non trovato.");
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      // 1. Recupero tutte le attività della giornata dal database
      final attivitaGrezze = await _activitiesRepo.fetchActivitiesByDate(
          boardId, widget.dataSelezionata);

      // 2. Filtro centralizzato tramite il Repository delle attività utili da mostrare
      var attivitaFiltrate = _activitiesRepo.filterValidActivities(attivitaGrezze);

      // 3. Ordinamento: Dalla più recente alla più vecchia
      attivitaFiltrate.sort((a, b) {
        if (a.startTime == null && b.startTime == null) return 0;
        if (a.startTime == null) return 1;
        if (b.startTime == null) return -1;
        return b.startTime!.compareTo(a.startTime!);
      });

      // 4. CALCOLO DEI TITOLI DELLE ATTIVITÀ
      for (var act in attivitaFiltrate) {
        // Ora il repo fa tutto il lavoro sporco per ogni stato!
        String titolo = await _activitiesRepo.getActivityLabel(act);
        _nomiZoneCalcolate[act.id] = titolo; 
      }

      if (mounted) {
        setState(() {
          _listaAttivita = attivitaFiltrate;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("❌ Errore caricamento note attività: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Mappa di configurazione per UI (Testo, Colore, Icona)
  Map<String, dynamic> _getConfigForActivity(Activities attivita) {
    // Ora la mappa contiene già il titolo perfetto per qualsiasi stato ('w', 'i', 's', ecc.)
    String titolo = _nomiZoneCalcolate[attivita.id] ?? 'Sconosciuta';

    switch (attivita.status.toLowerCase()) {
      case 's':
        return {'titolo': titolo, 'colore': Colors.red, 'icona': Icons.warning_amber_rounded};
      case 'w':
        return {'titolo': titolo, 'colore': Colors.purple, 'icona': Icons.directions_walk};
      case 'i':
        return {'titolo': titolo, 'colore': Colors.green, 'icona': Icons.home_rounded};
      case 'v':
        return {'titolo': titolo, 'colore': Colors.blue, 'icona': Icons.directions_car};
      default:
        return {'titolo': titolo, 'colore': Colors.grey, 'icona': Icons.help_outline};
    }
  }

  @override
  Widget build(BuildContext context) {
    String dataLabel =
        DateFormat('EEEE d MMMM', 'it_IT').format(widget.dataSelezionata);
    dataLabel = dataLabel[0].toUpperCase() + dataLabel.substring(1);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: Text(
          dataLabel,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: const Color(0xFFF7F8FA),
        elevation: 0,
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00C6B8)))
          : _listaAttivita.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  itemCount: _listaAttivita.length,
                  itemBuilder: (context, index) {
                    final attivita = _listaAttivita[index];
                    return _buildNotaAttivita(attivita);
                  },
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notes_rounded, size: 80, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text(
            "Nessuna attività registrata\nin questa data.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.black45),
          ),
        ],
      ),
    );
  }

  Widget _buildNotaAttivita(Activities attivita) {
    // Passiamo l'intero oggetto attività per poter leggere il suo ID
    final config = _getConfigForActivity(attivita);
    final String titolo = config['titolo'];
    final Color colore = config['colore'];
    final IconData icona = config['icona'];

    final formatOrario = DateFormat('HH:mm');
    String oraInizio = attivita.startTime != null
        ? formatOrario.format(attivita.startTime!)
        : "--:--";
        
    String oraFine = attivita.endTime != null
        ? formatOrario.format(attivita.endTime!)
        : "In corso";

   return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ActivityDetailsScreen(
              attivita: attivita,
              titoloZona: titolo, // Passiamo il titolo (es. "Giardino") per l'AppBar
              coloreStato: colore, // Passiamo il colore per la linea GPS
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colore.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icona, color: colore, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titolo,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.access_time_rounded,
                            size: 14, color: Colors.grey.shade500),
                        const SizedBox(width: 6),
                        Text(
                          "$oraInizio - $oraFine",
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Aggiungiamo una piccola freccina per far capire che è cliccabile
              const Icon(Icons.chevron_right, color: Colors.black26),
            ],
          ),
        ),
      ),
    );
  }
}