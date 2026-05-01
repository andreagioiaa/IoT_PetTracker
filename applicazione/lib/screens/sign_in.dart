import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pet_tracker/services/util.dart';
import 'login.dart';
import 'home.dart';
import "../repositories/users_repo.dart";

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  // Stato per gestire il caricamento e la visibilità della password
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // Controller per i campi di input
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();
  final TextEditingController _boardIdController = TextEditingController();

  // --- LOGICA DI VALIDAZIONE AGGIORNATA ---
  String? _getValidationError() {
    final name = _nameController.text.trim();
    final surname = _surnameController.text.trim();
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final confirmPass = _confirmPassController.text.trim();
    final boardId = _boardIdController.text.trim();

    // 1. Controllo campi vuoti
    if (name.isEmpty ||
        surname.isEmpty ||
        username.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPass.isEmpty ||
        boardId.isEmpty) {
      return "Tutti i campi sono obbligatori.";
    }

    // 2. Controllo Nome e Cognome (Limiti minimi, massimi e caratteri)
    if (name.length < 2 || name.length > 50) {
      return "Il nome deve essere compreso tra 2 e 50 caratteri.";
    }
    if (surname.length < 2 || surname.length > 50) {
      return "Il cognome deve essere compreso tra 2 e 50 caratteri.";
    }

    // Solo lettere, spazi, apostrofi e lettere accentate
    final nameRegex = RegExp(r"^[a-zA-Zàèéìíòóùú\s\']+$");
    if (!nameRegex.hasMatch(name) || !nameRegex.hasMatch(surname)) {
      return "Nome e cognome possono contenere solo lettere.";
    }

    // 3. Controllo Username (Limiti minimi, massimi e caratteri)
    if (username.length < 6 || username.length > 15) {
      return "Lo username deve essere tra 6 e 15 caratteri.";
    }
    // Solo lettere (minuscole/maiuscole), numeri, underscore e niente spazi.
    final usernameRegex = RegExp(r'^[a-zA-Z0-9_]+$');
    if (!usernameRegex.hasMatch(username)) {
      return "Lo username può contenere solo lettere, numeri e underscore (_). Nessuno spazio.";
    }

    // 4. Email Regex: Controlla che sia un formato email valido
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      return "Inserisci un indirizzo email valido.";
    }

    // 5. Password Regex: Minimo 8 caratteri, almeno una maiuscola, un numero e un simbolo speciale
    final passwordRegex = RegExp(
        r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[!@#\$%^&*(),.?":{}|<>]).{8,}$');

    if (!passwordRegex.hasMatch(password)) {
      return "La password richiede: 8+ caratteri, una maiuscola, un numero e un simbolo speciale.";
    }

    // 6. Controllo Conferma Password
    if (password != confirmPass) {
      return "Le password non coincidono.";
    }

    // 7. Controllo Board ID: Esattamente 15 numeri
    final boardIdRegex = RegExp(r'^\d{15}$');
    if (!boardIdRegex.hasMatch(boardId)) {
      return "Il codice Board deve essere composto esattamente da 15 numeri.";
    }

    return null;
  }

  final UsersRepository _usersRepo = UsersRepository();

  void _submitSignInForm() async {
    // 1. Validazione sintattica locale dei campi
    final error = _getValidationError();
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
      final boardId = _boardIdController.text.trim();

      // 2. Chiamata al Repository per la registrazione
      // MODIFICA: Ora è un String? e si chiama registrationError
      String? registrationError = await _usersRepo.register(
        email,
        password,
        name,
        surname,
        username,
        boardId,
      );

      if (registrationError == null) {
        // 3. Login Automatico dopo la registrazione tramite Repository
        bool loggedIn = await _usersRepo.login(email, password);

        if (loggedIn) {
          if (!mounted) return;
          _showSnackBar('Account creato e collegato alla Board!',
              const Color(0xFF00C6B8));

          // Pulizia controller per sicurezza
          _clearControllers();

          // Navigazione verso la Home
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (context) => const PetTrackerNavigation()),
          );
        } else {
          // Registrazione OK, ma login fallito: rimanda all'AuthScreen
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const AuthScreen()),
          );
        }
      } else {
        // 4. Errore restituito dal server (es. dati duplicati o board inesistente)
        _showSnackBar(registrationError, Colors.red);
      }
    } catch (e) {
      _showSnackBar('Si è verificato un errore imprevisto: $e', Colors.red);
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
    _confirmPassController.clear();
    _boardIdController.clear();
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
    _confirmPassController.dispose();
    _boardIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double screenHeight = MediaQuery.of(context).size.height;
    double scale = dimensioniSchermo(context);

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
                  _buildTextField(
                    _passwordController,
                    'Password',
                    Icons.lock_outline,
                    scale,
                    obscure: _obscurePassword,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: Colors.black26,
                        size: 22 * scale,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                  ),
                  SizedBox(height: 12 * scale),
                  _buildTextField(
                    _confirmPassController,
                    'Conferma Password',
                    Icons.lock_outline,
                    scale,
                    obscure: _obscureConfirmPassword,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: Colors.black26,
                        size: 22 * scale,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureConfirmPassword = !_obscureConfirmPassword;
                        });
                      },
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, left: 4.0),
                    child: Text(
                      "Minimo 8 caratteri compresi di Maiuscola, Numero e Simbolo (es. @)",
                      style: TextStyle(
                          fontSize: 10 * scale, color: Colors.black38),
                    ),
                  ),

                  SizedBox(height: 25 * scale),

                  _buildTextField(
                    _boardIdController,
                    'Codice Board',
                    Icons.memory_outlined, // Icona in tema con l'hardware
                    scale,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter
                          .digitsOnly, // Permette solo numeri a tastiera
                      LengthLimitingTextInputFormatter(
                          15), // Blocca la digitazione a 15 caratteri
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, left: 4.0),
                    child: Text(
                      "Inserire esattamente 15 cifre numeriche",
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
                  SizedBox(height: 30 * scale),
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
      {bool obscure = false,
      Widget? suffixIcon,
      TextInputType? keyboardType,
      List<TextInputFormatter>? inputFormatters}) {
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
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.black38, fontSize: 14),
          prefixIcon:
              Icon(icon, color: const Color(0xFF00C6B8), size: 22 * scale),
          suffixIcon: suffixIcon,
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        ),
      ),
    );
  }
}
