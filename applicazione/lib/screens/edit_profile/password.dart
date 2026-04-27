import 'package:flutter/material.dart';
import '../../repositories/users_repo.dart';

class ChangePasswordScreen extends StatefulWidget {
  final UsersRepository usersRepo;
  const ChangePasswordScreen({super.key, required this.usersRepo});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obs1 = true;
  bool _obs2 = true;
  bool _obs3 = true;
  bool _isLoading = false;
  String? _errorMessage;

  final RegExp _passwordRegex = RegExp(
      r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[!@#\$%^&*(),.?":{}|<>]).{8,}$');

  void _updatePassword() async {
    final cur = _currentController.text.trim();
    final next = _newController.text.trim();
    final conf = _confirmController.text.trim();

    if (cur.isEmpty || next.isEmpty || conf.isEmpty) {
      setState(() => _errorMessage = "Tutti i campi sono obbligatori.");
      return;
    }
    if (next != conf) {
      setState(() => _errorMessage = "Le nuove password non coincidono.");
      return;
    }
    if (!_passwordRegex.hasMatch(next)) {
      setState(() => _errorMessage =
          "Aggiorna la tua password: deve contenere 8+ caratteri, una maiuscola, un numero e un simbolo.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    bool success = await widget.usersRepo.updatePassword(cur, next);

    setState(() => _isLoading = false);

    if (success) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Password aggiornata!")));
      Navigator.pop(context);
    } else {
      setState(
          () => _errorMessage = "Password attuale errata o errore di rete.");
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
                      color: Colors.orange.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.security_rounded,
                        size: 32 * scale, color: Colors.orange),
                  ),
                  SizedBox(width: 15 * scale),
                  Expanded(
                    child: Text("Sicurezza",
                        style: TextStyle(
                            fontSize: 26 * scale,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87)),
                  ),
                ],
              ),

              SizedBox(height: 15 * scale),
              Text(
                  "La tua password deve contenere almeno 8 caratteri, una lettera maiuscola, un numero e un simbolo.",
                  style: TextStyle(
                      fontSize: 14 * scale,
                      color: Colors.black54,
                      height: 1.4)),

              SizedBox(height: 40 * scale),

              // --- FORM RAGGRUPPATO ---
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
                    // PASSWORD ATTUALE: Usiamo la CHIAVE (Icons.vpn_key_outlined)
                    _buildCleanPassField(
                        _currentController,
                        "Password Attuale",
                        _obs1,
                        () => setState(() => _obs1 = !_obs1),
                        scale,
                        Icons.lock_outline),

                    Divider(
                        height: 1,
                        indent: 50 * scale,
                        color: Colors.grey.shade200),

                    // NUOVA PASSWORD
                    _buildCleanPassField(
                        _newController,
                        "Nuova Password",
                        _obs2,
                        () => setState(() => _obs2 = !_obs2),
                        scale,
                        Icons.enhanced_encryption_outlined),

                    Divider(
                        height: 1,
                        indent: 50 * scale,
                        color: Colors.grey.shade200),

                    _buildCleanPassField(
                        _confirmController,
                        "Conferma Nuova Password",
                        _obs3,
                        () => setState(() => _obs3 = !_obs3),
                        scale,
                        Icons.enhanced_encryption_outlined),
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
              _buildSubmitButton(scale),
            ],
          ),
        ),
      ),
    );
  }

  // Helper aggiornato con lo scale
  Widget _buildCleanPassField(TextEditingController ctrl, String label,
      bool obs, VoidCallback toggle, double scale, IconData icon) {
    return TextField(
      controller: ctrl,
      obscureText: obs,
      style: TextStyle(fontSize: 15 * scale),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.black45, fontSize: 14 * scale),
        prefixIcon:
            Icon(icon, color: const Color(0xFF00C6B8), size: 24 * scale),
        suffixIcon: IconButton(
            icon: Icon(obs ? Icons.visibility_off : Icons.visibility,
                color: Colors.black26, size: 22 * scale),
            onPressed: toggle),
        border: InputBorder.none,
        contentPadding:
            EdgeInsets.symmetric(horizontal: 15 * scale, vertical: 15 * scale),
      ),
    );
  }

  // Tasto aggiornato con lo scale
  Widget _buildSubmitButton(double scale) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _updatePassword,
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
            : Text("AGGIORNA PASSWORD",
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    fontSize: 14 * scale)),
      ),
    );
  }
}
