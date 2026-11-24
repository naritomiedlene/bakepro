import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bakepro/models/app_user.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSessionController extends ChangeNotifier {
  bool _initialized = false;
  AppUser? _profile;
  bool _mustChangePassword = false;
  String? _empresaNome;
  String? _empresaLogoUrl;
  Uint8List? _empresaLogoBytes;
  String? _empresaLogoMime;

  static const _prefsKeyEmail = 'session_email';
  String? _email;

  bool get isInitialized => _initialized;
  bool get isSignedIn => _profile != null;
  AppUser? get profile => _profile;
  int? get empresaId => _profile?.empresaId;
  String? get email => _email;
  String? get empresaNome => _empresaNome;
  String? get empresaLogoUrl => _empresaLogoUrl;
  Uint8List? get empresaLogoBytes => _empresaLogoBytes;
  String? get empresaLogoMime => _empresaLogoMime;
  String get empresaLabel {
    final nome = (_empresaNome ?? '').trim();
    if (nome.isNotEmpty) return nome;
    final id = empresaId;
    if (id != null) return 'Empresa #$id';
    return 'Admin';
  }
  /// A (Administrador) ou E (Administrador da Empresa)
  bool get isAdminEmpresa {
    final tipo = (_profile?.tipoUsuario ?? '').trim().toUpperCase();
    return tipo == 'A' || tipo == 'E';
  }

  /// Administrador geral (nível sistema).
  ///
  /// Usado quando queremos permitir trocar/selecionar empresa livremente.
  bool get isSuperAdmin {
    final tipo = (_profile?.tipoUsuario ?? '').trim().toUpperCase();
    return tipo == 'A';
  }

  /// Mantido por compatibilidade com código existente.
  bool get isAdministrador => isAdminEmpresa;
  bool get mustChangePassword => _mustChangePassword;

  Future<void> start() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefsKeyEmail);
      final normalized = stored?.trim().toLowerCase();
      if (normalized != null && normalized.isNotEmpty) {
        _email = normalized;
        await _refreshProfile();
      }
    } catch (e) {
      debugPrint('AppSessionController.start failed: $e');
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> signInWithEmailPassword({required String email, required String password}) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty || password.isEmpty) {
      throw Exception('Email/senha inválidos.');
    }

    try {
      final row = await SupabaseService.selectSingle(
        'usuario',
        select: 'usuarioid, empresaid, tipousuario, nome, sobrenome, email, status, dataprimeiroacesso, senha',
        filters: {'email': normalizedEmail},
      );

      if (row == null) {
        throw Exception('Email/senha inválidos.');
      }

      final status = (row['status']?.toString() ?? '').trim().toUpperCase();
      if (status.isNotEmpty && status != 'A') {
        throw Exception('Usuário inativo.');
      }

      final storedPw = (row['senha']?.toString() ?? '');
      if (storedPw != password) {
        throw Exception('Email/senha inválidos.');
      }

      _email = normalizedEmail;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyEmail, normalizedEmail);

      _profile = AppUser.fromJson(row);
      _mustChangePassword = _profile?.dataPrimeiroAcesso == null;
      await _refreshEmpresaHeader(_profile);
    } catch (e) {
      debugPrint('AppSessionController.signInWithEmailPassword failed: $e');
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKeyEmail);
      _email = null;
      _profile = null;
      _mustChangePassword = false;
      _empresaNome = null;
      _empresaLogoUrl = null;
      _empresaLogoBytes = null;
      _empresaLogoMime = null;
      notifyListeners();
    } catch (e) {
      debugPrint('AppSessionController.signOut failed: $e');
      rethrow;
    }
  }

  Future<void> reloadProfile() async => _refreshProfile();

  Future<void> markPasswordChanged() async {
    _mustChangePassword = false;
    notifyListeners();
  }

  Future<void> _refreshProfile() async {
    final email = _email;
    if (email == null || email.isEmpty) {
      _profile = null;
      _mustChangePassword = false;
      _empresaNome = null;
      _empresaLogoUrl = null;
      _empresaLogoBytes = null;
      _empresaLogoMime = null;
      notifyListeners();
      return;
    }

    try {
      final row = await SupabaseService.selectSingle(
        'usuario',
        filters: {'email': email},
      );

      if (row == null) {
        debugPrint('No usuario row found for email=$email; signing out.');
        await signOut();
        _profile = null;
        _mustChangePassword = false;
        _empresaNome = null;
        _empresaLogoUrl = null;
        notifyListeners();
        return;
      }

      final user = AppUser.fromJson(row);
      debugPrint('Loaded usuario profile: email=$email usuarioId=${user.usuarioId} empresaId=${user.empresaId} tipousuario=${user.tipoUsuario}');
      if ((user.status ?? '').toUpperCase() != 'A') {
        debugPrint('User is not active (status=${user.status}); signing out.');
        await signOut();
        _profile = null;
        _mustChangePassword = false;
        _empresaNome = null;
        _empresaLogoUrl = null;
        notifyListeners();
        return;
      }

      _profile = user;
      _mustChangePassword = user.dataPrimeiroAcesso == null;
      await _refreshEmpresaHeader(user);
    } catch (e) {
      debugPrint('Failed to refresh usuario profile: $e');
      // Keep previous state if any.
    } finally {
      notifyListeners();
    }
  }

  Future<void> _refreshEmpresaHeader(AppUser? user) async {
    _empresaNome = null;
    _empresaLogoUrl = null;
    _empresaLogoBytes = null;
    _empresaLogoMime = null;

    final empresaId = user?.empresaId;
    if (empresaId == null) return;

    try {
      final empresaRow = await SupabaseService.selectSingle(
        'empresa',
        filters: {'empresaid': empresaId},
      );

      final nomeFantasia = empresaRow?['nomefantasia']?.toString().trim();
      final razaoSocial = empresaRow?['razaosocial']?.toString().trim();
      final resolved = (nomeFantasia != null && nomeFantasia.isNotEmpty) ? nomeFantasia : razaoSocial;
      if (resolved != null && resolved.isNotEmpty) {
        _empresaNome = resolved;
      }

      final base64Candidates = <String>[
        'logo_base64',
        'logobase64',
        'imagemlogo_base64',
        'imagem_logo_base64',
        'logo',
      ];
      String? foundBase64;
      for (final key in base64Candidates) {
        final v = empresaRow?[key]?.toString().trim();
        if (v != null && v.isNotEmpty && v.toLowerCase() != 'null') {
          final lower = v.toLowerCase();
          if (lower.startsWith('http://') || lower.startsWith('https://')) continue;
          foundBase64 = v;
          break;
        }
      }

      final rawMime = (empresaRow?['logo_mime'] ?? empresaRow?['logomime'])?.toString().trim();
      if (rawMime != null && rawMime.isNotEmpty && rawMime.toLowerCase() != 'null') {
        _empresaLogoMime = rawMime;
      }

      if (foundBase64 != null) {
        try {
          _empresaLogoBytes = base64Decode(foundBase64);
        } catch (e) {
          debugPrint('Failed to decode empresa logo_base64 for empresaId=$empresaId: $e');
          _empresaLogoBytes = null;
        }
      }

      if (_empresaLogoBytes == null) {
        final urlCandidates = <String>[
          'logourl',
          'logo_url',
          'logopath',
          'logo_path',
          'imagemlogo',
          'imagem_logo',
          'logo',
        ];
        for (final key in urlCandidates) {
          final v = empresaRow?[key]?.toString().trim();
          if (v != null && v.isNotEmpty && v.toLowerCase() != 'null') {
            _empresaLogoUrl = v;
            break;
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to load empresa name/logo for empresaId=$empresaId: $e');
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}
