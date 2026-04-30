import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/util.dart';
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

  // --- STATO DELLA PAGINA ---
  bool _isLoading = true;
  List<Activities> _listaAttivita = [];
  final Map<String, String> _nomiZoneCalcolate = {};
  
  // Memorizza il BoardID per il Real-Time
  String? _boardId; 

  // --- LOGICA FILTRI ---
  final Map<String, String> _filtriDisponibili = {
    's': 'Scappato',
    'w': 'Passeggiate',
    'i': 'Zone sicure',
    'v': 'In viaggio'
  };
  
  Set<String> _filtriAttivi = {'s', 'w', 'i', 'v'}; 

  @override
  void initState() {
    super.initState();
    _inizializzaPagina();
  }

  // --- GESTIONE REAL-TIME ---
  Future<void> _inizializzaPagina() async {
    // 1. Carica le attività attuali
    await _caricaAttivitaGiornaliere();
    
    // 2. Attiva l'ascoltatore in tempo reale se abbiamo trovato il Board ID
    if (_boardId != null) {
      _attivaRealTimeAttivita();
    }
  }

  void _attivaRealTimeAttivita() async {
    // Attivare subito il Real-Time, altrimenti dopo averlo recuperato durante il caricamento
    await _activitiesRepo.subscribeToActivityUpdates(_boardId!, (data) {
      // Se arriva un aggiornamento dal server ricarichiamo la lista
      if (mounted) {
        bool isOggi = DateUtils.isSameDay(widget.dataSelezionata, DateTime.now());
        if (isOggi) {
          debugPrint("📡 [daily_recap]: Aggiornamento Real-Time ricevuto. Ricarico la lista...");
          _caricaAttivitaGiornaliere(); 
        }
      }
    });
  }

  @override
  void dispose() {
    // Rimuove Real-Time quando si esce dalla pagina
    _activitiesRepo.unsubscribeFromActivities();
    super.dispose();
  }
  // -------------------------

  Future<void> _caricaAttivitaGiornaliere() async {
    if (!mounted) return;
    
    // Mostra il caricamento solo se la lista è vuota (primo avvio)
    // Se è un aggiornamento Real-Time, aggiorna in background
    if (_listaAttivita.isEmpty) {
      setState(() => _isLoading = true);
    }

    try {
      _boardId ??= await _usersRepo.getBoardIdFromBoards();

      if (_boardId == null || _boardId!.isEmpty) {
        debugPrint("⚠️[daily_recap]: Board ID non trovato.");
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final attivitaGrezze = await _activitiesRepo.fetchActivitiesByDate(
          _boardId!, widget.dataSelezionata);

      var attivitaFiltrate = _activitiesRepo.filterValidActivities(attivitaGrezze);

      attivitaFiltrate.sort((a, b) {
        if (a.startTime == null && b.startTime == null) return 0;
        if (a.startTime == null) return 1;
        if (b.startTime == null) return -1;
        return b.startTime!.compareTo(a.startTime!);
      });

      for (var act in attivitaFiltrate) {
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

  // Restituisce titolo, colore e icona in base allo stato dell'attività
  Map<String, dynamic> _getConfigForActivity(Activities attivita) {
    String titolo = _nomiZoneCalcolate[attivita.id] ?? 'Sconosciuta';

    switch (attivita.status.toLowerCase()) {
      case 's':
        return {'titolo': titolo, 'colore': Colors.red, 'icona': Icons.warning_amber_rounded};
      case 'w':
        return {'titolo': titolo, 'colore': const Color(0xFF00C6B8), 'icona': Icons.directions_walk};
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
    String dataLabel = DateFormat('EEEE d MMMM', 'it_IT').format(widget.dataSelezionata);
    dataLabel = dataLabel[0].toUpperCase() + dataLabel.substring(1);

    double scale = dimensioniSchermo(context);

    List<Activities> attivitaDaMostrare = _listaAttivita.where((act) {
      return _filtriAttivi.contains(act.status.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: Text(
          dataLabel,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18 * scale),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          _buildPannelloFiltri(scale),
          
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00C6B8)))
                : _listaAttivita.isEmpty
                    ? _buildEmptyState("Nessuna attività registrata\nin questa data.", scale)
                    : attivitaDaMostrare.isEmpty
                        ? _buildEmptyState("Nessuna attività corrisponde\nai filtri selezionati.", scale)
                        : ListView.builder(
                            padding: EdgeInsets.symmetric(horizontal: 16 * scale, vertical: 10 * scale),
                            itemCount: attivitaDaMostrare.length,
                            itemBuilder: (context, index) {
                              final attivita = attivitaDaMostrare[index];
                              return _buildNotaAttivita(attivita, scale);
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildPannelloFiltri(double scale) {
    bool tutteAttive = _filtriAttivi.length == _filtriDisponibili.length;

    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: EdgeInsets.only(bottom: 10 * scale),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 16 * scale),
        child: Row(
          children: [
            _buildSingoloFiltro(
              etichetta: "Tutte", 
              selezionato: tutteAttive, 
              scale: scale,
              onTap: (selezionato) {
                setState(() {
                  if (selezionato) {
                    _filtriAttivi = Set.from(_filtriDisponibili.keys);
                  } else {
                    _filtriAttivi.clear();
                  }
                });
              }
            ),
            
            ..._filtriDisponibili.entries.map((entry) {
              return _buildSingoloFiltro(
                etichetta: entry.value,
                selezionato: _filtriAttivi.contains(entry.key),
                scale: scale,
                onTap: (selezionato) {
                  setState(() {
                    if (selezionato) {
                      _filtriAttivi.add(entry.key);
                    } else {
                      _filtriAttivi.remove(entry.key);
                    }
                  });
                }
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildSingoloFiltro({required String etichetta, required bool selezionato, required double scale, required Function(bool) onTap}) {
    return Padding(
      padding: EdgeInsets.only(right: 8 * scale),
      child: FilterChip(
        label: Text(etichetta, style: TextStyle(fontSize: 13 * scale, fontWeight: selezionato ? FontWeight.bold : FontWeight.normal)),
        selected: selezionato,
        onSelected: onTap,
        selectedColor: const Color(0xFF00C6B8).withOpacity(0.15),
        checkmarkColor: const Color(0xFF009B90),
        backgroundColor: const Color(0xFFF7F8FA),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20 * scale),
          side: BorderSide(
            color: selezionato ? const Color(0xFF00C6B8) : Colors.grey.shade300,
            width: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(String messaggio, double scale) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notes_rounded, size: 80 * scale, color: Colors.grey.shade300),
          SizedBox(height: 16 * scale),
          Text(
            messaggio,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16 * scale, color: Colors.black45),
          ),
        ],
      ),
    );
  }

  Widget _buildNotaAttivita(Activities attivita, double scale) {
    final config = _getConfigForActivity(attivita);
    final String titolo = config['titolo'];
    final Color colore = config['colore'];
    final IconData icona = config['icona'];

    // Formatta orari
    String oraInizio = formattaOrarioEsatto(attivita.startTime);
    
    // Se l'attività è ancora attiva, mostriamo "In corso..." altrimenti l'orario di fine (oppure "N.D." se non disponibile)
    String oraFine = attivita.isActive 
        ? "In corso..." 
        : (attivita.endTime != null ? formattaOrarioEsatto(attivita.endTime) : "N.D.");

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ActivityDetailsScreen(
              attivita: attivita,
              titoloZona: titolo, 
              coloreStato: colore, 
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 16 * scale),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16 * scale),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(16.0 * scale),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.all(12 * scale),
                decoration: BoxDecoration(
                  color: colore.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icona, color: colore, size: 24 * scale),
              ),
              SizedBox(width: 16 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titolo,
                      style: TextStyle(
                        fontSize: 16 * scale,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    SizedBox(height: 6 * scale),
                    Row(
                      children: [
                        Icon(Icons.access_time_rounded,
                            size: 14 * scale, color: Colors.grey.shade500),
                        SizedBox(width: 6 * scale),
                        Text(
                          "$oraInizio - $oraFine",
                          style: TextStyle(
                            fontSize: 14 * scale,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.black26, size: 24 * scale),
            ],
          ),
        ),
      ),
    );
  }
}