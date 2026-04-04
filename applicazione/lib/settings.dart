import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'scambio.dart' as scambio;

class SettingsModal extends StatefulWidget {
  final VoidCallback onProfileUpdated;

  const SettingsModal({super.key, required this.onProfileUpdated});

  @override
  State<SettingsModal> createState() => _SettingsModalState();
}

class _SettingsModalState extends State<SettingsModal> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _surnameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  
  // Controller sicurezza
  final TextEditingController _currentPassController = TextEditingController();
  final TextEditingController _newPassController = TextEditingController();
  final TextEditingController _confirmPassController = TextEditingController();
  
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  bool _isLoading = false;
  bool _isChangingPassword = false;
  bool _photoRemoved = false;
  String? _inlineErrorMessage;

  Uint8List? _imageBytes; 
  String? _imageName; 
  final ImagePicker _picker = ImagePicker();

  final RegExp _passwordRegex = RegExp(r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$');

  @override
  void initState() {
    super.initState();
    _nameController.text = scambio.pb.authStore.model?.getStringValue('name') ?? '';
    _surnameController.text = scambio.pb.authStore.model?.getStringValue('surname') ?? '';
    _usernameController.text = scambio.pb.authStore.model?.getStringValue('username') ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _surnameController.dispose();
    _usernameController.dispose();
    _currentPassController.dispose();
    _newPassController.dispose();
    _confirmPassController.dispose();
    super.dispose();
  }

  bool _validateFields() {
    setState(() => _inlineErrorMessage = null);

    if (_isChangingPassword) {
      final attuale = _currentPassController.text.trim();
      final nuova = _newPassController.text.trim();
      final conferma = _confirmPassController.text.trim();

      if (attuale.isEmpty || nuova.isEmpty || conferma.isEmpty) {
        setState(() => _inlineErrorMessage = "Tutti i campi password sono obbligatori.");
        return false;
      }
      if (nuova == attuale) {
        setState(() => _inlineErrorMessage = "La nuova password deve essere diversa.");
        return false;
      }
      if (nuova != conferma) {
        setState(() => _inlineErrorMessage = "Le nuove password non coincidono.");
        return false;
      }
      if (!_passwordRegex.hasMatch(nuova)) {
        setState(() => _inlineErrorMessage = "8+ car., maiuscola, numero e speciale.");
        return false;
      }
    }
    return true;
  }

  void _salvaModifiche() async {
    if (!_validateFields()) return;

    setState(() => _isLoading = true);
    
    bool successAvatar = true;
    if (_photoRemoved) {
      successAvatar = await scambio.rimuoviAvatar();
    } else if (_imageBytes != null && _imageName != null) {
      successAvatar = await scambio.aggiornaAvatar(_imageBytes!, _imageName!);
    }

    bool successAnagrafica = await scambio.aggiornaProfilo(
      _nameController.text.trim(),
      _surnameController.text.trim(),
    );

    bool successPassword = true;
    if (_isChangingPassword) {
      // Passiamo sia la vecchia che la nuova password
      successPassword = await scambio.aggiornaPassword(
        _currentPassController.text.trim(),
        _newPassController.text.trim()
      );
      
      if (!successPassword) {
        setState(() => _inlineErrorMessage = "Password attuale errata o errore server.");
      }
    }

    setState(() => _isLoading = false);

    if (successAnagrafica && successAvatar && successPassword) {
      widget.onProfileUpdated();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 15),
      decoration: const BoxDecoration(
        color: Color(0xFFF7F8FA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: Column(
        children: [
          Container(width: 40, height: 5, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Impostazioni", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 15),
                  _buildAvatarPicker(),
                  const SizedBox(height: 35),
                  
                  _buildSectionLabel("ACCOUNT"),
                  _buildTextField(_usernameController, "Username", Icons.alternate_email, enabled: false),
                  
                  const SizedBox(height: 25),
                  _buildSectionLabel("DATI PERSONALI"),
                  _buildTextField(_nameController, "Nome", Icons.person_outline),
                  const SizedBox(height: 15),
                  _buildTextField(_surnameController, "Cognome", Icons.badge_outlined),
                  
                  const SizedBox(height: 25),
                  _buildPasswordSection(),
                  
                  const SizedBox(height: 40),
                  _buildSaveButton(),
                  const SizedBox(height: 20),
                  _buildLogoutButton(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarPicker() {
    return Center(
      child: Stack(
        children: [
          CircleAvatar(
            radius: 55,
            backgroundColor: Colors.white,
            backgroundImage: _photoRemoved ? null : (_imageBytes != null ? MemoryImage(_imageBytes!) : (scambio.getAvatarUrl().isNotEmpty ? NetworkImage(scambio.getAvatarUrl(), headers: const {'ngrok-skip-browser-warning': 'true'}) : null) as ImageProvider?),
            child: (_photoRemoved || (scambio.getAvatarUrl().isEmpty && _imageBytes == null)) ? const Icon(Icons.person, size: 50, color: Colors.grey) : null,
          ),
          Positioned(bottom: 0, right: 0, child: _smallCircleButton(Icons.camera_alt_rounded, const Color(0xFF00C6B8), _pickImage)),
          if (!_photoRemoved && (_imageBytes != null || scambio.getAvatarUrl().isNotEmpty))
            Positioned(bottom: 0, left: 0, child: _smallCircleButton(Icons.delete_forever_rounded, Colors.redAccent, _confirmPhotoDeletion)),
        ],
      ),
    );
  }

  Widget _buildPasswordSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel("SICUREZZA"),
        InkWell(
          onTap: () => setState(() => _isChangingPassword = !_isChangingPassword),
          borderRadius: BorderRadius.circular(15),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
            child: Row(
              children: [
                Icon(Icons.lock_reset_rounded, color: _isChangingPassword ? const Color(0xFF00C6B8) : Colors.black45),
                const SizedBox(width: 15),
                const Text("Cambia Password", style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Icon(_isChangingPassword ? Icons.expand_less : Icons.expand_more, color: Colors.black26),
              ],
            ),
          ),
        ),
        if (_isChangingPassword) ...[
          if (_inlineErrorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 15, left: 5),
              child: Text(_inlineErrorMessage!, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          const SizedBox(height: 12),
          _buildPasswordField(_currentPassController, "Password Attuale", _obscureCurrent, () => setState(() => _obscureCurrent = !_obscureCurrent)),
          const SizedBox(height: 10),
          _buildPasswordField(_newPassController, "Nuova Password", _obscureNew, () => setState(() => _obscureNew = !_obscureNew)),
          const SizedBox(height: 10),
          _buildPasswordField(_confirmPassController, "Conferma Nuova Password", _obscureConfirm, () => setState(() => _obscureConfirm = !_obscureConfirm)),
        ],
      ],
    );
  }

  Widget _buildPasswordField(TextEditingController ctrl, String label, bool obscure, VoidCallback toggle) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)]),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.vpn_key_outlined, color: Color(0xFF00C6B8)),
          suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.black26), onPressed: toggle),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController ctrl, String label, IconData icon, {bool enabled = true}) {
    return Container(
      decoration: BoxDecoration(color: enabled ? Colors.white : Colors.grey.shade100, borderRadius: BorderRadius.circular(15)),
      child: TextField(
        controller: ctrl,
        enabled: enabled,
        decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon, color: enabled ? const Color(0xFF00C6B8) : Colors.black26), border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15)),
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, bottom: 8),
      child: Text(label, style: const TextStyle(color: Colors.black38, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 1.1)),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _salvaModifiche,
        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C6B8), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
        child: _isLoading ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text("SALVA MODIFICHE", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    );
  }

  Widget _buildLogoutButton() {
    return Center(
      child: TextButton.icon(
        onPressed: _confirmLogout,
        icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
        label: const Text("ESCI DALL'ACCOUNT", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _confirmLogout() {
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Logout"), content: const Text("Sei sicuro?"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("ANNULLA")),
        TextButton(onPressed: () { Navigator.pop(context); scambio.eseguiLogout(context); }, child: const Text("ESCI", style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  void _confirmPhotoDeletion() {
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Rimuovere foto?"), content: const Text("L'azione sarà definitiva al salvataggio."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("ANNULLA")),
        TextButton(onPressed: () { setState(() { _photoRemoved = true; _imageBytes = null; }); Navigator.pop(context); }, child: const Text("RIMUOVI", style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 85);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      setState(() { _imageBytes = bytes; _imageName = pickedFile.name; _photoRemoved = false; });
    }
  }

  Widget _smallCircleButton(IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Icon(icon, color: Colors.white, size: 18)));
  }
}