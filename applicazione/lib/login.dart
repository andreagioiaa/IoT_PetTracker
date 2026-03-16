import 'package:flutter/material.dart';
import 'home.dart';
import 'data/mock_data.dart'; // Importiamo il file dei dati fittizi

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

  void _submitForm() {
    if (isLoginMode) {
      // LOGICA DI LOGIN CON MOCK DATA
      final usernameInput = _usernameController.text.trim();
      final passwordInput = _passwordController.text.trim();

      // Cerchiamo se esiste un utente con quel nome e password nella lista mock
      bool isAuthenticated = registeredUsers.any((user) =>
          user.name.toLowerCase() == usernameInput.toLowerCase() &&
          user.password == passwordInput);

      if (isAuthenticated) {
        // Accesso eseguito correttamente -> Vai alla Home
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const PetTrackerNavigation()),
        );
      } else {
        // Messaggio richiesto dal docente in caso di errore
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nome utente e/o Password errati'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      // LOGICA SIGN IN (Simulata)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registrazione completata! Effettua il login.'),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        isLoginMode = true;
      });
    }
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
      appBar: AppBar(
        title: Text(isLoginMode ? 'LOGIN' : 'SIGN IN'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.teal,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.pets, size: 80, color: Colors.teal),
              const SizedBox(height: 30),
              
              if (!isLoginMode) ...[
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Nome',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _surnameController,
                  decoration: const InputDecoration(
                    labelText: 'Cognome',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Nome utente',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _submitForm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  isLoginMode ? 'ACCEDI' : 'REGISTRATI',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() {
                    isLoginMode = !isLoginMode;
                  });
                },
                child: Text(
                  isLoginMode 
                      ? 'Non hai un account? SIGN IN' 
                      : 'Hai già un account? LOGIN',
                  style: const TextStyle(color: Colors.teal),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}