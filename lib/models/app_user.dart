class AppUser {
  const AppUser({
    required this.usuarioId,
    this.empresaId,
    this.tipoUsuario,
    required this.nome,
    required this.sobrenome,
    required this.email,
    this.status,
    this.dataPrimeiroAcesso,
  });

  final int usuarioId;
  final int? empresaId;
  /// A (Administrador), E (Administrador da Empresa) ou U (Usuário)
  final String? tipoUsuario;
  final String nome;
  final String sobrenome;
  final String email;
  final String? status;
  /// Nullable in DB; when null the user must change password at first login.
  final DateTime? dataPrimeiroAcesso;

  String get fullName => '$nome $sobrenome'.trim();

  static String? _readString(Map<String, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v == null) continue;
      final s = v.toString();
      if (s.trim().isEmpty) continue;
      return s;
    }
    return null;
  }

  static int? _readInt(Map<String, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v == null) continue;
      if (v is num) return v.toInt();
      final n = num.tryParse(v.toString());
      if (n != null) return n.toInt();
    }
    return null;
  }

  static DateTime? _readDateTime(Map<String, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (v == null) continue;
      if (v is DateTime) return v;
      final parsed = DateTime.tryParse(v.toString());
      if (parsed != null) return parsed;
    }
    return null;
  }

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
    usuarioId: (_readInt(json, const ['usuarioid', 'usuarioId']) ?? 0),
    empresaId: _readInt(json, const ['empresaid', 'empresaId']),
    // Some schemas use quoted camelCase column names; accept multiple variants.
    tipoUsuario: _readString(json, const ['tipousuario', 'tipoUsuario', 'tipo_usuario'])?.trim(),
    nome: _readString(json, const ['nome']) ?? '',
    sobrenome: _readString(json, const ['sobrenome']) ?? '',
    email: _readString(json, const ['email']) ?? '',
    status: _readString(json, const ['status']),
    dataPrimeiroAcesso: _readDateTime(json, const ['dataprimeiroacesso', 'dataPrimeiroAcesso']),
  );

  Map<String, dynamic> toJson() => {
    'usuarioid': usuarioId,
    'empresaid': empresaId,
    'tipousuario': tipoUsuario,
    'nome': nome,
    'sobrenome': sobrenome,
    'email': email,
    'status': status,
    'dataprimeiroacesso': dataPrimeiroAcesso?.toIso8601String(),
  };

  AppUser copyWith({
    int? usuarioId,
    int? empresaId,
    String? tipoUsuario,
    String? nome,
    String? sobrenome,
    String? email,
    String? status,
    DateTime? dataPrimeiroAcesso,
  }) => AppUser(
    usuarioId: usuarioId ?? this.usuarioId,
    empresaId: empresaId ?? this.empresaId,
    tipoUsuario: tipoUsuario ?? this.tipoUsuario,
    nome: nome ?? this.nome,
    sobrenome: sobrenome ?? this.sobrenome,
    email: email ?? this.email,
    status: status ?? this.status,
    dataPrimeiroAcesso: dataPrimeiroAcesso ?? this.dataPrimeiroAcesso,
  );
}
