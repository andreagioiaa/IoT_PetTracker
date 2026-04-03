import 'package:flutter/material.dart';
import 'home.dart';
import 'scambio.dart' as scambio;

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isLoginMode = true;
  bool _isLoading = false;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();

  // --- VALIDAZIONE SINTATTICA ---
  String? _getValidationError() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    if (username.isEmpty || password.isEmpty) return "Inserisci credenziali";
    if (!isLoginMode) {
      if (_nameController.text.isEmpty || _surnameController.text.isEmpty) return "Nome e Cognome obbligatori";
      if (password.length < 6) return "Password troppo corta";
    }
    return null;
  }

  void _submitForm() async {
    final error = _getValidationError();
    if (error != null) {
      _showSnackBar(error, Colors.orange.shade800);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final identity = _usernameController.text.trim();
      final password = _passwordController.text.trim();

      if (isLoginMode) {
        // Chiamata a PocketBase
        bool auth = await scambio.loginUtente(identity, password);
        if (auth) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const PetTrackerNavigation()),
          );
        } else {
          _showSnackBar('Accesso fallito. Controlla i dati.', Colors.red);
        }
      } else {
        _showSnackBar('Registrazione via API in arrivo...', Colors.blue);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color, behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _surnameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double screenHeight = MediaQuery.of(context).size.height;
    // Calcolo scale identico alla Home
    double scale = (screenHeight / 800).clamp(0.7, 1.1);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Stack(
        children: [
          // Decorazione Gradiante (Stile Home)
          Positioned(
            top: -20,
            right: -20,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.45,
              height: screenHeight * 0.15,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)]),
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(80)),
              ),
            ),
          ),
          
          SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: 30.0 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 40 * scale),
                  // Logo
                  Row(
                    children: [
                      const Icon(Icons.pets, size: 36, color: Color(0xFF00C6B8)),
                      const SizedBox(width: 10),
                      Text('PET TRACKER', 
                        style: TextStyle(
                          fontSize: 14 * scale, 
                          fontWeight: FontWeight.bold, 
                          color: const Color(0xFF00C6B8),
                          letterSpacing: 1.5
                        )),
                    ],
                  ),
                  SizedBox(height: 60 * scale),
                  
                  // Titolo d'impatto (senza "Bentornato")
                  Text(isLoginMode ? 'Accedi ora' : 'Inizia qui',
                      style: TextStyle(
                        fontSize: 34 * scale, 
                        fontWeight: FontWeight.bold, 
                        color: const Color(0xFF2D3142),
                        letterSpacing: -0.5
                      )),
                  
                  SizedBox(height: 40 * scale),

                  // Form Campi
                  if (!isLoginMode) ...[
                    _buildTextField(_nameController, 'Nome', Icons.badge_outlined, scale),
                    SizedBox(height: 15 * scale),
                    _buildTextField(_surnameController, 'Cognome', Icons.badge_outlined, scale),
                    SizedBox(height: 15 * scale),
                  ],
                  _buildTextField(_usernameController, 'Email o Username', Icons.person_outline, scale),
                  SizedBox(height: 15 * scale),
                  _buildTextField(_passwordController, 'Password', Icons.lock_outline, scale, obscure: true),
                  
                  SizedBox(height: 40 * scale),

                  // Bottone Login
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitForm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00C6B8),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 18 * scale),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                        elevation: 4,
                        shadowColor: const Color(0xFF00C6B8).withOpacity(0.3),
                      ),
                      child: _isLoading 
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(isLoginMode ? 'ACCEDI' : 'REGISTRATI', 
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),

                  SizedBox(height: 20 * scale),
                  
                  // Switch Mode
                  Center(
                    child: TextButton(
                      onPressed: () => setState(() => isLoginMode = !isLoginMode),
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(color: Colors.black54, fontSize: 14),
                          children: [
                            TextSpan(text: isLoginMode ? "Non hai un account? " : "Hai già un account? "),
                            TextSpan(
                              text: isLoginMode ? "Registrati" : "Accedi",
                              style: const TextStyle(color: Color(0xFF00C6B8), fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label, IconData icon, double scale, {bool obscure = false}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.black38, fontSize: 14),
          prefixIcon: Icon(icon, color: const Color(0xFF00C6B8), size: 22 * scale),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        ),
      ),
    );
  }
}