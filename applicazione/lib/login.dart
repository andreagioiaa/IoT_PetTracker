import 'package:flutter/material.dart';
import 'home.dart';
import 'data/mock_data.dart';
import 'scambio.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isLoginMode = true;

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();

  // --- FUNZIONE DI VALIDAZIONE SINTATTICA ---
  String? _getValidationError() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();
    final surname = _surnameController.text.trim();

    // 1. Controllo campi vuoti universali
    if (username.isEmpty || password.isEmpty) {
      return "Inserisci nome utente e password";
    }

    // 2. Controlli specifici per la Registrazione (SIGN IN)
    if (!isLoginMode) {
      if (name.isEmpty || surname.isEmpty) {
        return "Nome e Cognome sono obbligatori";
      }
      if (password.length < 6) {
        return "La password deve contenere almeno 6 caratteri";
      }
      // Controllo che il nome non contenga numeri (Esempio sintattico avanzato)
      if (RegExp(r'[0-9]').hasMatch(name) ||
          RegExp(r'[0-9]').hasMatch(surname)) {
        return "Nome e Cognome non possono contenere numeri";
      }
    }

    return null; // Nessun errore trovato
  }

// Aggiungi una variabile per il caricamento
  bool _isLoading = false;

  void _submitForm() async { // Aggiunto async
    final error = _getValidationError();

    if (error != null) {
      _showSnackBar(error, Colors.orange.shade800);
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (isLoginMode) {
        final emailInput = _usernameController.text.trim();
        final passwordInput = _passwordController.text.trim();

        // CHIAMATA A POCKETBASE
        bool isAuthenticated = await loginUtente(emailInput, passwordInput);

        if (isAuthenticated) {
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const PetTrackerNavigation()),
          );
        } else {
          _showSnackBar('Credenziali non valide o errore di connessione', Colors.red);
        }
      } else {
        // TODO: Implementare registrazione su PocketBase
        _showSnackBar('Registrazione non ancora implementata su PB', Colors.blue);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Helper per snellire il codice
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
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 30.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.pets, size: 90, color: Colors.teal),
                const SizedBox(height: 10),
                const Text(
                  'Pet Tracker',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 50),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    isLoginMode ? 'LOGIN' : 'SIGN IN',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2D3142),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (!isLoginMode) ...[
                  _buildTextField(
                      _nameController, 'Nome', Icons.badge_outlined),
                  const SizedBox(height: 15),
                  _buildTextField(
                      _surnameController, 'Cognome', Icons.badge_outlined),
                  const SizedBox(height: 15),
                ],
                _buildTextField(
                    _usernameController, 'Nome utente', Icons.person_outline),
                const SizedBox(height: 15),
                _buildTextField(
                    _passwordController, 'Password', Icons.lock_outline,
                    obscure: true),
                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitForm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      isLoginMode ? 'ACCEDI' : 'REGISTRATI',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () {
                    setState(() {
                      isLoginMode = !isLoginMode;
                    });
                  },
                  child: Text(
                    isLoginMode
                        ? 'Non hai un account? Registrati ora'
                        : 'Hai già un account? Accedi qui',
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
      TextEditingController controller, String label, IconData icon,
      {bool obscure = false}) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.teal.withOpacity(0.7)),
        filled: true,
        fillColor: Colors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: Colors.grey.shade200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Colors.teal, width: 2),
        ),
      ),
    );
  }
}

