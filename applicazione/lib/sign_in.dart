import 'package:flutter/material.dart';
import 'login.dart';
import 'home.dart';
import 'scambio.dart' as scambio;

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _isLoading = false;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // --- LOGICA DI VALIDAZIONE PASSWORD "KING" ---
  // --- LOGICA DI VALIDAZIONE AGGIORNATA ---
  String? _getValidationError() {
    final name = _nameController.text.trim();
    final surname = _surnameController.text.trim();
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    // 1. Controllo campi vuoti
    if (name.isEmpty ||
        surname.isEmpty ||
        username.isEmpty ||
        email.isEmpty ||
        password.isEmpty) {
      return "Tutti i campi sono obbligatori.";
    }

    // 2. Controllo lunghezze (Target: 30 per flessibilità)
    if (name.length > 30) return "Il nome è troppo lungo (max 30 caratteri).";
    if (surname.length > 30)
      return "Il cognome è troppo lungo (max 30 caratteri).";

    // Username tra 6 e 15
    if (username.length < 6 || username.length > 15) {
      return "Lo username deve essere tra 6 e 15 caratteri.";
    }

    // 3. Email Regex
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      return "Inserisci un indirizzo email valido.";
    }

    // 4. Password Validation "Anti-Mediocrità"
    // Ho espanso il set di caratteri speciali includendo la @ in modo più esplicito
    // La sequenza [!@#\$%^&*(),.?":{}|<>] copre quasi tutto lo standard
    final passwordRegex = RegExp(
        r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[!@#\$%^&*(),.?":{}|<>]).{8,}$');

    if (!passwordRegex.hasMatch(password)) {
      return "La password richiede: 8+ caratteri, una maiuscola, un numero e un simbolo (es. @, !, #).";
    }

    return null;
  }

  void _submitSignInForm() async {
    final error = _getValidationError(); //
    if (error != null) {
      _showSnackBar(error, Colors.orange.shade800);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final name = _nameController.text.trim();
      final surname = _surnameController.text.trim();
      final username = _usernameController.text.trim();
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();

      // Registrazione su PocketBase
      bool success = await scambio.registraUtente(
        email,
        password,
        name,
        surname,
        username,
      );

      if (success) {
        // Login Automatico
        bool loggedIn = await scambio.loginUtente(email, password);

        if (loggedIn) {
          if (!mounted) return;
          _showSnackBar('Account creato! Benvenuto.', const Color(0xFF00C6B8));

          // Pulizia controller per sicurezza prima della navigazione
          _clearControllers();

          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (context) => const PetTrackerNavigation()),
          );
        } else {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const AuthScreen()),
          );
        }
      } else {
        _showSnackBar('Errore: Email o Username potrebbero essere già in uso.',
            Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _clearControllers() {
    _nameController.clear();
    _surnameController.clear();
    _usernameController.clear();
    _emailController.clear();
    _passwordController.clear();
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(message),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _clearControllers();
    _nameController.dispose();
    _surnameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = (screenHeight / 800).clamp(0.7, 1.1);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Stack(
        children: [
          Positioned(
            top: -20,
            right: -20,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.45,
              height: screenHeight * 0.15,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [Color(0xFF00E2C1), Color(0xFF00C6B8)]),
                borderRadius:
                    BorderRadius.only(bottomLeft: Radius.circular(80)),
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
                      const Icon(Icons.pets,
                          size: 36, color: Color(0xFF00C6B8)),
                      const SizedBox(width: 10),
                      Text('PET TRACKER',
                          style: TextStyle(
                              fontSize: 14 * scale,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF00C6B8),
                              letterSpacing: 1.5)),
                    ],
                  ),
                  SizedBox(height: 40 * scale),

                  Text('Crea Account',
                      style: TextStyle(
                          fontSize: 34 * scale,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF2D3142),
                          letterSpacing: -0.5)),

                  SizedBox(height: 30 * scale),

                  _buildTextField(
                      _nameController, 'Nome', Icons.badge_outlined, scale),
                  SizedBox(height: 12 * scale),
                  _buildTextField(_surnameController, 'Cognome',
                      Icons.badge_outlined, scale),
                  SizedBox(height: 12 * scale),
                  _buildTextField(_usernameController, 'Username',
                      Icons.alternate_email, scale),
                  SizedBox(height: 12 * scale),
                  _buildTextField(
                      _emailController, 'Email', Icons.email_outlined, scale),
                  SizedBox(height: 12 * scale),
                  _buildTextField(_passwordController, 'Password',
                      Icons.lock_outline, scale,
                      obscure: true),

                  // Suggerimento visivo per l'utente (Opzionale ma utile)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, left: 4.0),
                    child: Text(
                      "Min. 8 caratteri: Maiuscola, Numero e Simbolo (es. @)",
                      style: TextStyle(
                          fontSize: 10 * scale, color: Colors.black38),
                    ),
                  ),

                  SizedBox(height: 35 * scale),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submitSignInForm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00C6B8),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 18 * scale),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15)),
                        elevation: 4,
                        shadowColor: const Color(0xFF00C6B8).withOpacity(0.3),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2))
                          : const Text('REGISTRATI',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),

                  SizedBox(height: 20 * scale),

                  Center(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                              builder: (context) => const AuthScreen()),
                        );
                      },
                      child: RichText(
                        text: const TextSpan(
                          style: TextStyle(color: Colors.black54, fontSize: 14),
                          children: [
                            TextSpan(text: "Hai già un account? "),
                            TextSpan(
                              text: "Accedi",
                              style: TextStyle(
                                  color: Color(0xFF00C6B8),
                                  fontWeight: FontWeight.bold),
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

  Widget _buildTextField(TextEditingController controller, String label,
      IconData icon, double scale,
      {bool obscure = false}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.black38, fontSize: 14),
          prefixIcon:
              Icon(icon, color: const Color(0xFF00C6B8), size: 22 * scale),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        ),
      ),
    );
  }
}
