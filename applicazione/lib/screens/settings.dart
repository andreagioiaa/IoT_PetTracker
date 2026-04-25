import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/authentication.dart' as scambio;
import '../services/position_gps.dart';
import 'home.dart';
import "../repositories/users_repo.dart"; // Rimuovi 'as users' se preferisci usare la classe direttamente
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onProfileUpdated;

  const SettingsScreen({super.key, required this.onProfileUpdated});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Istanzia il repository qui
  final UsersRepository _usersRepo = UsersRepository();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _emailController =
      TextEditingController(); // <-- Aggiunto

  final TextEditingController _currentPassController = TextEditingController();
  final TextEditingController _newPassController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  bool _isLoading = false;
  bool _isChangingPassword = false;
  String? _inlineErrorMessage;

  final RegExp _passwordRegex = RegExp(
      r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[!@#\$%^&*(),.?":{}|<>]).{8,}$'); // <-- Regex aggiornata

  // Variabili per tracciare le modifiche (Dirty Check)
  late String _initialName;
  late String _initialSurname;
  late String _initialMapFocus;
  late String _currentMapFocus;
  bool _isDirty = false;

  @override
  void initState() {
    super.initState();

    // Inizializzazione dati profilo
    _initialName = scambio.pb.authStore.model?.getStringValue('name') ?? '';
    _initialSurname =
        scambio.pb.authStore.model?.getStringValue('surname') ?? '';

    _nameController.text = _initialName;
    _surnameController.text = _initialSurname;

    _usernameController.text =
        scambio.pb.authStore.model?.getStringValue('username') ?? '';
    // Estrazione email da PocketBase
    _emailController.text =
        scambio.pb.authStore.model?.getStringValue('email') ?? '';

    // Inizializzazione preferenze mappa (Locali alla pagina)
    _initialMapFocus = mapFocusPreference.value;
    _currentMapFocus = _initialMapFocus;

    // Listener per rilevare modifiche in tempo reale
    _nameController.addListener(_checkChanges);
    _surnameController.addListener(_checkChanges);
    _currentPassController.addListener(_checkChanges);
    _newPassController.addListener(_checkChanges);
    _confirmPassController.addListener(_checkChanges);

    _checkPermissionStatus();
  }

  @override
  void dispose() {
    _nameController.removeListener(_checkChanges);
    _surnameController.removeListener(_checkChanges);
    _currentPassController.removeListener(_checkChanges);
    _newPassController.removeListener(_checkChanges);
    _confirmPassController.removeListener(_checkChanges);

    _nameController.dispose();
    _surnameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _currentPassController.dispose();
    _newPassController.dispose();
    _confirmPassController.dispose();
    super.dispose();
  }

  // --- LOGICA DI CONTROLLO MODIFICHE ---
  void _checkChanges() {
    final nameChanged = _nameController.text.trim() != _initialName;
    final surnameChanged = _surnameController.text.trim() != _initialSurname;
    final passwordEntered = _currentPassController.text.isNotEmpty ||
        _newPassController.text.isNotEmpty ||
        _confirmPassController.text.isNotEmpty;
    final mapFocusChanged = _currentMapFocus != _initialMapFocus;

    final isNowDirty =
        nameChanged || surnameChanged || passwordEntered || mapFocusChanged;

    if (isNowDirty != _isDirty) {
      setState(() => _isDirty = isNowDirty);
    }
  }

  // --- POP-UP DI AVVISO USCITA ---
  void _handleBackPress() async {
    if (!_isDirty) {
      Navigator.pop(context);
      return;
    }

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Modifiche non salvate"),
        content: const Text(
            "Se esci ora, le modifiche apportate andranno perse. Vuoi uscire?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child:
                const Text("ANNULLA", style: TextStyle(color: Colors.black54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("ESCI",
                style:
                    TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isDirty = false);
      if (mounted) Navigator.pop(context);
    }
  }

  // --- GESTIONE PERMESSI GPS ---
  Future<void> _checkPermissionStatus() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    LocationPermission permission = await Geolocator.checkPermission();

    bool hasGrant = (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse);
    hasLocationPermission.value = serviceEnabled && hasGrant;

    // Se i permessi vengono revocati mentre si è sulla pagina, resetta il focus su Animale
    if (!hasLocationPermission.value && _currentMapFocus == 'Dispositivo') {
      setState(() {
        _currentMapFocus = 'Animale';
        _checkChanges();
      });
    }
  }

  Future<void> _togglePermission() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // Se negati, li chiediamo
      permission = await Geolocator.requestPermission();
    } else if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      // Se sono già concessi (o negati per sempre), l'unico modo per
      // "modificarli" davvero è mandare l'utente nelle impostazioni del telefono
      await Geolocator.openAppSettings();
    }

    // Dopo il ritorno dalle impostazioni o dalla scelta, aggiorniamo la lampadina
    await _checkPermissionStatus();
  }

  // --- VALIDAZIONE E SALVATAGGIO AGGIORNATA ---
  bool _validateFields() {
    setState(() => _inlineErrorMessage = null);

    final name = _nameController.text.trim();
    final surname = _surnameController.text.trim();

    // 1. Controllo campi anagrafici vuoti
    if (name.isEmpty || surname.isEmpty) {
      setState(() => _inlineErrorMessage = "Nome e Cognome sono obbligatori.");
      return false;
    }

    // 2. Controllo lunghezze (2 - 50 caratteri)
    if (name.length < 2 || name.length > 50) {
      setState(() => _inlineErrorMessage =
          "Il nome deve essere compreso tra 2 e 50 caratteri.");
      return false;
    }
    if (surname.length < 2 || surname.length > 50) {
      setState(() => _inlineErrorMessage =
          "Il cognome deve essere compreso tra 2 e 50 caratteri.");
      return false;
    }

    // 3. Controllo caratteri validi (solo lettere)
    final nameRegex = RegExp(r"^[a-zA-Zàèéìíòóùú\s\']+$");
    if (!nameRegex.hasMatch(name) || !nameRegex.hasMatch(surname)) {
      setState(() => _inlineErrorMessage =
          "Nome e cognome possono contenere solo lettere.");
      return false;
    }

    // 4. Controlli Password (se sta cambiando)
    if (_isChangingPassword) {
      final attuale = _currentPassController.text.trim();
      final nuova = _newPassController.text.trim();
      final conferma = _confirmPassController.text.trim();

      if (attuale.isEmpty || nuova.isEmpty || conferma.isEmpty) {
        setState(() => _inlineErrorMessage = "Campi password obbligatori.");
        return false;
      }
      if (nuova != conferma) {
        setState(() => _inlineErrorMessage = "Le password non coincidono.");
        return false;
      }
      if (!_passwordRegex.hasMatch(nuova)) {
        setState(() => _inlineErrorMessage =
            "La password richiede: 8+ caratteri, una maiuscola, un numero e un simbolo speciale.");
        return false;
      }
    }
    return true;
  }

  void _salvaModifiche() async {
    if (!_validateFields()) return;
    setState(() => _isLoading = true);

    // 1. Salvataggio su database (PocketBase)
    bool successAnagrafica = await _usersRepo.updateProfile(
      _nameController.text.trim(),
      _surnameController.text.trim(),
    );

    bool successPassword = true;
    if (_isChangingPassword) {
      successPassword = await _usersRepo.updatePassword(
          _currentPassController.text.trim(), _newPassController.text.trim());
    }

    // 2. Salvataggio Preferenze Locali (Focus Mappa)
    if (successAnagrafica && successPassword) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('map_focus_priority', _currentMapFocus);

      // Aggiorna il ValueNotifier globale così le altre schermate reagiscono subito
      mapFocusPreference.value = _currentMapFocus;
    }

    setState(() => _isLoading = false);

    if (!successAnagrafica || !successPassword) {
      setState(() => _inlineErrorMessage =
          "Errore di connessione o password attuale errata.");
      return;
    }

    widget.onProfileUpdated();
    setState(() => _isDirty = false);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.7, 1.2);

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF7F8FA),
          elevation: 0,
          centerTitle: true,
          title: Text("Impostazioni",
              style:
                  TextStyle(fontWeight: FontWeight.bold, fontSize: 22 * scale)),
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, size: 24 * scale),
            onPressed: _handleBackPress,
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
                horizontal: 25 * scale, vertical: 10 * scale),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 20 * scale),
                _buildSectionLabel("ACCOUNT", scale),
                _buildTextField(_usernameController, "Username",
                    Icons.alternate_email, scale,
                    enabled: false),
                SizedBox(height: 15 * scale),
                // Nuova email bloccata (enabled: false)
                _buildTextField(
                    _emailController, "Email", Icons.email_outlined, scale,
                    enabled: false),
                SizedBox(height: 25 * scale),
                _buildSectionLabel("DATI PERSONALI", scale),
                _buildTextField(
                    _nameController, "Nome", Icons.person_outline, scale),
                SizedBox(height: 15 * scale),
                _buildTextField(
                    _surnameController, "Cognome", Icons.badge_outlined, scale),
                SizedBox(height: 25 * scale),
                _buildPermissionsSection(scale),
                SizedBox(height: 25 * scale),
                _buildMapPreferencesSection(scale),
                SizedBox(height: 25 * scale),
                _buildPasswordSection(scale),
                SizedBox(height: 30 * scale),

                // Messaggio d'errore globale (mostra l'errore per Nome/Cognome e per Password)
                if (_inlineErrorMessage != null)
                  Padding(
                    padding: EdgeInsets.only(bottom: 15 * scale),
                    child: Center(
                      child: Text(_inlineErrorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.redAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 13 * scale)),
                    ),
                  ),

                _buildSaveButton(scale),
                SizedBox(height: 20 * scale),
                _buildLogoutButton(scale),
                SizedBox(height: 40 * scale),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionsSection(double scale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel("PERMESSI APP", scale),
        // InkWell rende l'intera riga cliccabile e scalabile
        InkWell(
          onTap: _togglePermission,
          borderRadius: BorderRadius.circular(15 * scale),
          child: Container(
            padding: EdgeInsets.all(16 * scale), // Padding scalato
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15 * scale),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 8 * scale)
                ]),
            child: ValueListenableBuilder<bool>(
              valueListenable: hasLocationPermission,
              builder: (context, hasPermission, child) {
                return Row(
                  children: [
                    Icon(
                      hasPermission ? Icons.location_on : Icons.location_off,
                      color: hasPermission
                          ? const Color(0xFF00C6B8)
                          : Colors.redAccent,
                      size: 28 * scale, // Icona scalata
                    ),
                    SizedBox(width: 15 * scale),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Posizione GPS",
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16 * scale), // Testo scalato
                          ),
                          Text(
                            hasPermission
                                ? "Autorizzato"
                                : "Non autorizzato (Clicca per gestire)",
                            style: TextStyle(
                                color: Colors.black38,
                                fontSize: 13 * scale), // Sottotitolo scalato
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.black12,
                      size: 16 * scale, // Freccetta scalata
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMapPreferencesSection(double scale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel("PREFERENZE MAPPA", scale),
        Container(
          padding: EdgeInsets.all(5 * scale),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15 * scale),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)
              ]),
          child: ValueListenableBuilder<bool>(
              valueListenable: hasLocationPermission,
              builder: (context, hasPermission, _) {
                return Column(
                  children: [
                    RadioListTile<String>(
                      title: Text("Focus Animale",
                          style: TextStyle(
                              fontSize: 14 * scale,
                              fontWeight: FontWeight.w600)),
                      subtitle: Text("Zoom sulla posizione dell'animale",
                          style: TextStyle(fontSize: 11 * scale)),
                      value: 'Animale',
                      groupValue: _currentMapFocus,
                      activeColor: const Color(0xFF00C6B8),
                      onChanged: (val) {
                        setState(() {
                          _currentMapFocus = val!;
                          _checkChanges();
                        });
                      },
                    ),
                    const Divider(indent: 20, endIndent: 20, height: 1),
                    RadioListTile<String>(
                      title: Text("Focus Dispositivo",
                          style: TextStyle(
                              fontSize: 14 * scale,
                              fontWeight: FontWeight.w600,
                              color: hasPermission
                                  ? Colors.black87
                                  : Colors.black38)),
                      subtitle: Text("Zoom sulla tua posizione",
                          style: TextStyle(
                              fontSize: 11 * scale,
                              color: hasPermission
                                  ? Colors.black54
                                  : Colors.black26)),
                      value: 'Dispositivo',
                      groupValue: _currentMapFocus,
                      activeColor: const Color(0xFF00C6B8),
                      onChanged: hasPermission
                          ? (val) {
                              setState(() {
                                _currentMapFocus = val!;
                                _checkChanges();
                              });
                            }
                          : null,
                    ),
                  ],
                );
              }),
        ),
      ],
    );
  }

  Widget _buildPasswordSection(double scale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel("SICUREZZA", scale),
        InkWell(
          onTap: () =>
              setState(() => _isChangingPassword = !_isChangingPassword),
          borderRadius: BorderRadius.circular(15 * scale),
          child: Container(
            padding: EdgeInsets.all(16 * scale),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(15 * scale),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.02), blurRadius: 8)
                ]),
            child: Row(
              children: [
                Icon(Icons.lock_reset_rounded,
                    size: 24 * scale,
                    color: _isChangingPassword
                        ? const Color(0xFF00C6B8)
                        : Colors.black45),
                SizedBox(width: 15 * scale),
                Text("Cambia Password",
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14 * scale)),
                const Spacer(),
                Icon(
                    _isChangingPassword ? Icons.expand_less : Icons.expand_more,
                    size: 24 * scale,
                    color: Colors.black26),
              ],
            ),
          ),
        ),
        if (_isChangingPassword) ...[
          SizedBox(height: 12 * scale),
          _buildPasswordField(
              _currentPassController,
              "Password Attuale",
              _obscureCurrent,
              () => setState(() => _obscureCurrent = !_obscureCurrent),
              scale),
          SizedBox(height: 10 * scale),
          _buildPasswordField(_newPassController, "Nuova Password", _obscureNew,
              () => setState(() => _obscureNew = !_obscureNew), scale),
          SizedBox(height: 10 * scale),
          _buildPasswordField(
              _confirmPassController,
              "Conferma Nuova Password",
              _obscureConfirm,
              () => setState(() => _obscureConfirm = !_obscureConfirm),
              scale),
        ],
      ],
    );
  }

  Widget _buildPasswordField(TextEditingController ctrl, String label,
      bool obscure, VoidCallback toggle, double scale) {
    return Container(
      margin: EdgeInsets.only(top: 10 * scale),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15 * scale),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)
          ]),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        style: TextStyle(fontSize: 14 * scale),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(fontSize: 14 * scale),
          prefixIcon: Icon(Icons.vpn_key_outlined,
              color: const Color(0xFF00C6B8), size: 22 * scale),
          suffixIcon: IconButton(
              icon: Icon(
                  obscure
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  color: Colors.black26,
                  size: 22 * scale),
              onPressed: toggle),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(
              horizontal: 20 * scale, vertical: 15 * scale),
        ),
      ),
    );
  }

  Widget _buildTextField(
      TextEditingController ctrl, String label, IconData icon, double scale,
      {bool enabled = true}) {
    return Container(
      decoration: BoxDecoration(
          color: enabled ? Colors.white : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(15 * scale),
          boxShadow: enabled
              ? [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.02), blurRadius: 8)
                ]
              : []),
      child: TextField(
        controller: ctrl,
        enabled: enabled,
        style: TextStyle(fontSize: 14 * scale),
        decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(fontSize: 14 * scale),
            prefixIcon: Icon(icon,
                color: enabled ? const Color(0xFF00C6B8) : Colors.black26,
                size: 22 * scale),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(
                horizontal: 20 * scale, vertical: 15 * scale)),
      ),
    );
  }

  Widget _buildSectionLabel(String label, double scale) {
    return Padding(
      padding: EdgeInsets.only(left: 5 * scale, bottom: 8 * scale),
      child: Text(label,
          style: TextStyle(
              color: Colors.black38,
              fontWeight: FontWeight.bold,
              fontSize: 11 * scale,
              letterSpacing: 1.1)),
    );
  }

  Widget _buildSaveButton(double scale) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _salvaModifiche,
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
                    fontWeight: FontWeight.bold, fontSize: 16 * scale)),
      ),
    );
  }

  Widget _buildLogoutButton(double scale) {
    return Center(
      child: TextButton.icon(
        onPressed: _confirmLogout,
        icon: Icon(Icons.logout_rounded,
            color: Colors.redAccent, size: 20 * scale),
        label: Text("ESCI DALL'ACCOUNT",
            style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14 * scale)),
      ),
    );
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Logout"),
        content: const Text("Sei sicuro di voler uscire?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ANNULLA"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context); // Chiude il dialog
              // CHIAMATA CORRETTA:
              _usersRepo.eseguiLogout(context);
            },
            child: const Text("ESCI", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
