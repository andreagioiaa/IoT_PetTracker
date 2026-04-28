import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/authentication.dart' as scambio;
import './globals/app_state.dart';
import "../repositories/users_repo.dart";
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'edit_profile/personal_data.dart';
import 'edit_profile/password.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onProfileUpdated;

  const SettingsScreen({super.key, required this.onProfileUpdated});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final UsersRepository _usersRepo = UsersRepository();

  // Variabili di stato per la UI
  late String _username;
  late String _email;
  late String _currentMapFocus;

  @override
  void initState() {
    super.initState();

    // Inizializzazione dati account (Sola lettura)
    _username = scambio.pb.authStore.model?.getStringValue('username') ?? '';
    _email = scambio.pb.authStore.model?.getStringValue('email') ?? '';

    // Inizializzazione preferenze mappa
    _currentMapFocus = mapFocusPreference.value;

    _checkPermissionStatus();
  }

  // --- GESTIONE PERMESSI  ---
  Future<void> _checkPermissionStatus() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    LocationPermission permission = await Geolocator.checkPermission();

    bool hasGPS = (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse);
    hasLocationPermission.value = serviceEnabled && hasGPS;

    NotificationSettings settings =
        await FirebaseMessaging.instance.getNotificationSettings();
    hasNotificationPermission.value =
        (settings.authorizationStatus == AuthorizationStatus.authorized);

    // Se l'utente ha revocato il permesso GPS ma aveva "Focus Dispositivo" attivo, resettiamo a "Focus Animale" per evitare problemi di UX
    if (!hasLocationPermission.value && _currentMapFocus == 'Dispositivo') {
      _updateMapFocus('Animale');
    }
  }

  Future<void> _togglePermission() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    } else {
      await Geolocator.openAppSettings();
    }
    await _checkPermissionStatus();
  }

  // --- SALVATAGGIO ISTANTANEO PREFERENZE MAPPA ---
  Future<void> _updateMapFocus(String newValue) async {
    setState(() => _currentMapFocus = newValue);

    // Aggiorna subito lo stato globale per il resto dell'app
    mapFocusPreference.value = newValue;

    // Salva in locale
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('map_focus_priority', newValue);
  }

  @override
  Widget build(BuildContext context) {
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.7, 1.2);

    return Scaffold(
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
          onPressed: () => Navigator.pop(context), // Uscita libera!
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: 25 * scale, vertical: 10 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 10 * scale),

              // 1. ACCOUNT (Sola Lettura)
              _buildSectionLabel("ACCOUNT", scale),
              _buildReadOnlyTile(
                  Icons.alternate_email, "Username", _username, scale),
              SizedBox(height: 10 * scale),
              _buildReadOnlyTile(Icons.email_outlined, "Email", _email, scale),

              SizedBox(height: 25 * scale),

              // 2. GESTIONE PROFILO (Navigazione)
              _buildSectionLabel("GESTIONE PROFILO", scale),
              _buildNavigationTile(
                icon: Icons.person_outline,
                title: "Modifica Dati Personali",
                scale: scale,
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            PersonalDataScreen(usersRepo: _usersRepo)),
                  );
                  if (result == true) widget.onProfileUpdated();
                },
              ),
              SizedBox(height: 10 * scale),
              _buildNavigationTile(
                icon: Icons.lock_reset_rounded,
                title: "Cambia Password",
                scale: scale,
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) =>
                            ChangePasswordScreen(usersRepo: _usersRepo)),
                  );
                  if (result == true) widget.onProfileUpdated();
                },
              ),

              SizedBox(height: 25 * scale),

              // 3. PREFERENZE MAPPA (Azione istantanea)
              _buildMapPreferencesSection(scale),

              SizedBox(height: 25 * scale),

              // 4. PERMESSI APP (Azione di sistema)
              _buildPermissionsSection(scale),

              SizedBox(height: 40 * scale),

              // 5. LOGOUT
              _buildLogoutButton(scale),
              SizedBox(height: 40 * scale),
            ],
          ),
        ),
      ),
    );
  }

  // --- WIDGET BUILDERS ---

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

  Widget _buildReadOnlyTile(
      IconData icon, String label, String value, double scale) {
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 15 * scale),
      decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(15 * scale)),
      child: Row(
        children: [
          Icon(icon, color: Colors.black26, size: 22 * scale),
          SizedBox(width: 15 * scale),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      TextStyle(fontSize: 11 * scale, color: Colors.black45)),
              Text(value.isNotEmpty ? value : "-",
                  style: TextStyle(
                      fontSize: 14 * scale,
                      fontWeight: FontWeight.w500,
                      color: Colors.black54)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationTile(
      {required IconData icon,
      required String title,
      required VoidCallback onTap,
      required double scale}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15 * scale),
      child: Container(
        padding:
            EdgeInsets.symmetric(horizontal: 20 * scale, vertical: 18 * scale),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(15 * scale),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)
            ]),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00C6B8), size: 22 * scale),
            SizedBox(width: 15 * scale),
            Text(title,
                style: TextStyle(
                    fontSize: 14 * scale, fontWeight: FontWeight.w600)),
            const Spacer(),
            Icon(Icons.arrow_forward_ios_rounded,
                color: Colors.black26, size: 16 * scale),
          ],
        ),
      ),
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
                      onChanged: (val) => _updateMapFocus(val!),
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
                      onChanged:
                          hasPermission ? (val) => _updateMapFocus(val!) : null,
                    ),
                  ],
                );
              }),
        ),
      ],
    );
  }

  Widget _buildPermissionsSection(double scale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel("PERMESSI APP", scale),
        Container(
          padding: EdgeInsets.all(5 * scale),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(15 * scale),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)
              ]),
          child: Column(
            children: [
              _buildPermissionTile(
                  icon: Icons.location_on,
                  label: "Posizione GPS",
                  notifier: hasLocationPermission,
                  scale: scale),
              const Divider(indent: 60, endIndent: 20, height: 1),
              _buildPermissionTile(
                  icon: Icons.notifications_active,
                  label: "Notifiche Push",
                  notifier: hasNotificationPermission,
                  scale: scale),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionTile(
      {required IconData icon,
      required String label,
      required ValueNotifier<bool> notifier,
      required double scale}) {
    return ValueListenableBuilder<bool>(
      valueListenable: notifier,
      builder: (context, hasPerm, child) {
        return InkWell(
          onTap: _togglePermission,
          child: Padding(
            padding: EdgeInsets.all(16 * scale),
            child: Row(
              children: [
                Icon(icon,
                    color: hasPerm ? const Color(0xFF00C6B8) : Colors.redAccent,
                    size: 24 * scale),
                SizedBox(width: 15 * scale),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14 * scale)),
                      Text(
                          hasPerm
                              ? "Autorizzato"
                              : "Non autorizzato (Gestisci)",
                          style: TextStyle(
                              color: Colors.black38, fontSize: 12 * scale)),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios,
                    color: Colors.black12, size: 14 * scale),
              ],
            ),
          ),
        );
      },
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
              child: const Text("ANNULLA")),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _usersRepo.eseguiLogout(context);
            },
            child: const Text("ESCI", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
