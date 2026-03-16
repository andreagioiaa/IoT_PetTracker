class MockUser {
  final String email;
  final String password;
  final String name;

  MockUser({required this.email, required this.password, required this.name});
}

// Lista di utenti per il test
final List<MockUser> registeredUsers = [
  MockUser(email: "test@example.com", password: "angela", name: "alberto"),
  MockUser(email: "admin@dominio.it", password: "admin", name: "Admin"),
];