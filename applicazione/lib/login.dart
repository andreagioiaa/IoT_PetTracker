import 'package:flutter/material.dart';
import 'home.dart';
import 'scambio.dart' as scambio;
import 'sign_in.dart'; // Import necessario per la navigazione verso la registrazione
import "repositories/users_repo.dart";

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLoading = false;

  // Controller essenziali per il login
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // --- VALIDAZIONE SINTATTICA ---
  String? _getValidationError() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    
    if (username.isEmpty || password.isEmpty) {
      return "Inserisci credenziali";
    }
    return null;
  }

  // Aggiungi il repository come variabile di stato
  final UsersRepository _usersRepo = UsersRepository();

  void _submitForm() async {
    // ... validazione ...
    setState(() => _isLoading = true);
    
    try {
      // CAMBIO QUI: Usiamo il repo
      bool auth = await _usersRepo.login(
        _usernameController.text.trim(), 
        _passwordController.text.trim()
      );
      
      if (auth) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const PetTrackerNavigation()),
        );
      } else {
        _showSnackBar('Accesso fallito. Controlla i dati.', Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message), 
        backgroundColor: color, 
        behavior: SnackBarBehavior.floating
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
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
          // Decorazione Gradiente (In alto a destra)
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
                  
                  // Titolo
                  Text('Accedi ora',
                      style: TextStyle(
                        fontSize: 34 * scale, 
                        fontWeight: FontWeight.bold, 
                        color: const Color(0xFF2D3142),
                        letterSpacing: -0.5
                      )),
                  
                  SizedBox(height: 40 * scale),

                  // Campi Form
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
                        : const Text('ACCEDI', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),

                  SizedBox(height: 20 * scale),
                  
                  // Link per andare alla registrazione
                  Center(
                    child: TextButton(
                      onPressed: () {
                        // Navigazione verso SignInScreen
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (context) => const SignInScreen()),
                        );
                      },
                      child: RichText(
                        text: const TextSpan(
                          style: TextStyle(color: Colors.black54, fontSize: 14),
                          children: [
                            TextSpan(text: "Non hai un account? "),
                            TextSpan(
                              text: "Registrati",
                              style: TextStyle(color: Color(0xFF00C6B8), fontWeight: FontWeight.bold),
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