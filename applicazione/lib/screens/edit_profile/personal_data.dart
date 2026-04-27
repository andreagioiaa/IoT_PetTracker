import 'package:flutter/material.dart';
import '../../repositories/users_repo.dart';
import '../../services/authentication.dart' as scambio;

class PersonalDataScreen extends StatefulWidget {
  final UsersRepository usersRepo;
  const PersonalDataScreen({super.key, required this.usersRepo});

  @override
  State<PersonalDataScreen> createState() => _PersonalDataScreenState();
}

class _PersonalDataScreenState extends State<PersonalDataScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Pre-popoliamo i campi con i dati attuali
    _nameController.text =
        scambio.pb.authStore.model?.getStringValue('name') ?? '';
    _surnameController.text =
        scambio.pb.authStore.model?.getStringValue('surname') ?? '';
  }

  void _save() async {
    final name = _nameController.text.trim();
    final surname = _surnameController.text.trim();

    // Validazione
    if (name.isEmpty || surname.isEmpty) {
      setState(() => _errorMessage = "Nome e Cognome sono obbligatori.");
      return;
    }
    final nameRegex = RegExp(r"^[a-zA-Zàèéìíòóùú\s\']+$");
    if (!nameRegex.hasMatch(name) || !nameRegex.hasMatch(surname)) {
      setState(() => _errorMessage = "Usa solo lettere per nome e cognome.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    bool success = await widget.usersRepo.updateProfile(name, surname);

    setState(() => _isLoading = false);

    if (success) {
      Navigator.pop(context, true); // Torna indietro segnalando il successo
    } else {
      setState(() => _errorMessage = "Errore durante l'aggiornamento.");
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fattore di scala basato sull'altezza dello schermo
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.7, 1.2);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F8FA),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: 25.0 * scale, vertical: 10.0 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- INTESTAZIONE AFFIANCATA ---
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(12 * scale),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00C6B8).withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.manage_accounts_rounded,
                        size: 32 * scale, color: const Color(0xFF00C6B8)),
                  ),
                  SizedBox(width: 15 * scale),
                  Expanded(
                    child: Text("Dati Personali",
                        style: TextStyle(
                            fontSize: 26 * scale,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87)),
                  ),
                ],
              ),

              SizedBox(height: 15 * scale),
              Text(
                  "Aggiorna il tuo nome e cognome: devono essere composti solo da lettere e avere una lunghezza massima di 30 caratteri.",
                  style: TextStyle(
                      fontSize: 14 * scale,
                      color: Colors.black54,
                      height: 1.4)),

              SizedBox(height: 40 * scale),

              // --- FORM RAGGRUPPATO (STILE iOS) ---
              Container(
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20 * scale),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.03),
                          blurRadius: 15 * scale,
                          offset: Offset(0, 5 * scale))
                    ]),
                child: Column(
                  children: [
                    _buildCleanField(
                        _nameController, "Nome", Icons.person_outline, scale),
                    Divider(
                        height: 1,
                        indent: 50 * scale,
                        color: Colors.grey.shade200),
                    _buildCleanField(_surnameController, "Cognome",
                        Icons.badge_outlined, scale),
                  ],
                ),
              ),

              if (_errorMessage != null) ...[
                SizedBox(height: 20 * scale),
                Center(
                  child: Text(_errorMessage!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 14 * scale)),
                ),
              ],

              SizedBox(height: 40 * scale),
              _buildSaveButton(scale),
            ],
          ),
        ),
      ),
    );
  }

  // Helper aggiornato con lo scale
  Widget _buildCleanField(
      TextEditingController ctrl, String label, IconData icon, double scale) {
    return TextField(
      controller: ctrl,
      style: TextStyle(fontSize: 15 * scale),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.black45, fontSize: 14 * scale),
        prefixIcon:
            Icon(icon, color: const Color(0xFF00C6B8), size: 24 * scale),
        border: InputBorder.none,
        contentPadding:
            EdgeInsets.symmetric(horizontal: 15 * scale, vertical: 15 * scale),
      ),
    );
  }

  // Tasto aggiornato con lo scale
  Widget _buildSaveButton(double scale) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _save,
        style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00C6B8),
            foregroundColor: Colors.white,
            padding: EdgeInsets.symmetric(vertical: 18 * scale),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15 * scale))),
        child: _isLoading
            ? SizedBox(
                height: 20 * scale,
                width: 20 * scale,
                child: const CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2))
            : Text("SALVA MODIFICHE",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    fontSize: 14 * scale)),
      ),
    );
  }
}
