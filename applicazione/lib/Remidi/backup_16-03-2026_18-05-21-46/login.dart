import 'package:flutter/material.dart';

void main() {
  runApp(const PetTrackerApp());
}

class PetTrackerApp extends StatelessWidget {
  const PetTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pet Tracker App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      // Imposta la schermata di autenticazione all'avvio
      home: const AuthScreen(), 
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  // Variabile per gestire il toggle tra Login e Sign In
  bool isLoginMode = true; 

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();

  void _submitForm() {
    if (isLoginMode) {
      // Logica di Login manuale
      if (_usernameController.text == 'alberto' && 
          _passwordController.text == 'angela') {
        // Naviga verso la Home se le credenziali sono corrette
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      } else {
        // Mostra errore generico se le credenziali sono errate
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nome utente e/o Password errati'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      // Logica di Sign In (Registrazione) simulata per il futuro
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registrazione simulata. Ora effettua il Login!'),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        isLoginMode = true; // Torna al login dopo aver "registrato"
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
      appBar: AppBar(
        title: Text(isLoginMode ? 'Login' : 'Sign In'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Campi aggiuntivi mostrati solo in fase di Sign In
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
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _submitForm,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(
                  isLoginMode ? 'ACCEDI' : 'REGISTRATI',
                  style: const TextStyle(fontSize: 16),
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
                      ? 'Non hai un account? Crea un nuovo account' 
                      : 'Hai già un account? Torna al Login',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Schermata Home provvisoria
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard Pet Tracker'),
        centerTitle: true,
      ),
      body: const Center(
        child: Text(
          'Benvenuto, Alberto!',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}