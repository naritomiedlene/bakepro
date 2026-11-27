import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/components/bakepro_centered_logo.dart';
import 'package:bakepro/pages/cadastros/db_column_lengths.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ForcePasswordChangePage extends StatefulWidget {
  const ForcePasswordChangePage({super.key});

  @override
  State<ForcePasswordChangePage> createState() => _ForcePasswordChangePageState();
}

class _ForcePasswordChangePageState extends State<ForcePasswordChangePage> with SingleTickerProviderStateMixin {
  final _password1 = TextEditingController();
  final _password2 = TextEditingController();
  bool _isLoading = false;
  String? _error;
  bool _obscurePassword1 = true;
  bool _obscurePassword2 = true;

  late final AnimationController _enterCtrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
    final curve = CurvedAnimation(parent: _enterCtrl, curve: Curves.easeOutCubic);
    _fade = Tween<double>(begin: 0, end: 1).animate(curve);
    _slide = Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero).animate(curve);
    _enterCtrl.forward();
  }

  void _clearErrorOnUserInteraction() {
    if (_error == null) return;
    if (!mounted) return;
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _password1.dispose();
    _password2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final p1 = _password1.text;
    final p2 = _password2.text;
    setState(() {
      _error = null;
      _isLoading = true;
    });

    try {
      if (p1.length < 8) {
        setState(() => _error = 'A senha deve ter pelo menos 8 caracteres.');
        return;
      }
      if (p1 != p2) {
        setState(() => _error = 'As senhas não conferem.');
        return;
      }
      final controller = context.read<AppSessionController>();
      final usuarioId = controller.profile?.usuarioId;
      if (usuarioId == null) {
        setState(() => _error = 'Sessão inválida. Faça login novamente.');
        return;
      }

      // Nesta versão simplificada (sem supabase.auth), atualizamos a senha direto
      // no cadastro do usuário.
      await SupabaseService.update(
        'usuario',
        {'senha': p1},
        filters: {'usuarioid': usuarioId},
      );

      // Mark first access as completed.
      if (usuarioId != null) {
        // IMPORTANT: In this project the column `usuario.dataprimeiroacesso` is stored as
        // `timestamp without time zone` in Postgres. If we send an UTC ISO string (e.g. with `Z`),
        // Postgres will drop the timezone info and store the UTC clock time, which will look
        // "a few hours ahead" when you read it as local time.
        //
        // Therefore we persist local time here.
        await SupabaseService.update(
          'usuario',
          {'dataprimeiroacesso': DateTime.now().toIso8601String()},
          filters: {'usuarioid': usuarioId},
        );
      }

      await controller.reloadProfile();
      await controller.markPasswordChanged();
    } catch (e) {
      debugPrint('Force password change failed: $e');
      setState(() => _error = 'Não foi possível atualizar a senha.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _logout() async {
    try {
      await context.read<AppSessionController>().signOut();
    } catch (e) {
      debugPrint('Logout failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = context.watch<AppSessionController>().profile;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: AppSpacing.paddingLg,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(AppRadius.xl),
                        border: Border.all(color: cs.outline.withValues(alpha: 0.18)),
                      ),
                      child: FadeTransition(
                        opacity: _fade,
                        child: SlideTransition(
                          position: _slide,
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Center(child: BakeProCenteredLogo()),
                                const SizedBox(height: AppSpacing.lg),
                                Row(
                                  children: [
                                    Icon(Icons.key_rounded, color: cs.primary),
                                    const SizedBox(width: AppSpacing.sm),
                                    Expanded(
                                      child: Text(
                                        'Troca de senha obrigatória',
                                        style: Theme.of(context).textTheme.titleLarge,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                Text(
                                  'Olá, ${user?.fullName.isNotEmpty == true ? user!.fullName : 'usuário'}. No primeiro acesso você precisa definir uma nova senha.',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.lg),
                                TextField(
                                  controller: _password1,
                                  // Cursor no primeiro campo ao abrir.
                                  autofocus: true,
                                  // usuario.senha é varchar(20) no banco.
                                  maxLength: dbColumnMaxLength('usuario', 'senha'),
                                  obscureText: _obscurePassword1,
                                  textInputAction: TextInputAction.next,
                                  onTap: _clearErrorOnUserInteraction,
                                  onChanged: (_) => _clearErrorOnUserInteraction(),
                                  decoration: InputDecoration(
                                    labelText: 'Nova senha',
                                    prefixIcon: Icon(Icons.lock_reset_rounded, color: cs.onSurfaceVariant),
                                    suffixIcon: IconButton(
                                      tooltip: _obscurePassword1 ? 'Mostrar senha' : 'Ocultar senha',
                                      onPressed: () => setState(() => _obscurePassword1 = !_obscurePassword1),
                                      style: ButtonStyle(
                                        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                                        splashFactory: NoSplash.splashFactory,
                                      ),
                                      icon: Icon(
                                        _obscurePassword1 ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.md),
                                TextField(
                                  controller: _password2,
                                  maxLength: dbColumnMaxLength('usuario', 'senha'),
                                  obscureText: _obscurePassword2,
                                  textInputAction: TextInputAction.done,
                                  onTap: _clearErrorOnUserInteraction,
                                  onChanged: (_) => _clearErrorOnUserInteraction(),
                                  onSubmitted: (_) => _isLoading ? null : _submit(),
                                  decoration: InputDecoration(
                                    labelText: 'Confirmar nova senha',
                                    prefixIcon: Icon(Icons.check_rounded, color: cs.onSurfaceVariant),
                                    suffixIcon: IconButton(
                                      tooltip: _obscurePassword2 ? 'Mostrar senha' : 'Ocultar senha',
                                      onPressed: () => setState(() => _obscurePassword2 = !_obscurePassword2),
                                      style: ButtonStyle(
                                        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                                        splashFactory: NoSplash.splashFactory,
                                      ),
                                      icon: Icon(
                                        _obscurePassword2 ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: AppSpacing.md),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: cs.errorContainer.withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(AppRadius.lg),
                                      border: Border.all(color: cs.error.withValues(alpha: 0.25)),
                                    ),
                                    child: Padding(
                                      padding: AppSpacing.paddingMd,
                                      child: Row(
                                        children: [
                                          Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
                                          const SizedBox(width: AppSpacing.sm),
                                          Expanded(
                                            child: Text(
                                              _error!,
                                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                color: cs.onErrorContainer,
                                                height: 1.4,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: AppSpacing.lg),
                                Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton.icon(
                                        onPressed: _isLoading ? null : _submit,
                                        icon: _isLoading
                                            ? SizedBox(
                                                width: 18,
                                                height: 18,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: cs.onPrimary,
                                                ),
                                              )
                                            : Icon(Icons.save_rounded, color: cs.onPrimary),
                                        label: Text(
                                          _isLoading ? 'Salvando…' : 'Salvar senha',
                                          style: TextStyle(color: cs.onPrimary),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.md),
                                    OutlinedButton.icon(
                                      onPressed: _isLoading ? null : _logout,
                                      icon: Icon(Icons.logout_rounded, color: cs.primary),
                                      label: Text('Sair', style: TextStyle(color: cs.primary)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
