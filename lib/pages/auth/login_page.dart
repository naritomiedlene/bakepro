import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/components/bakepro_centered_logo.dart';
import 'package:bakepro/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _error;

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
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    setState(() {
      _error = null;
      _isLoading = true;
    });

    try {
      await context.read<AppSessionController>().signInWithEmailPassword(email: email, password: password);
      // Router redirect will handle next screen.
    } catch (e) {
      debugPrint('Login failed: $e');
      final msg = e.toString();
      // Our sign-in throws friendly messages, but `Exception: ...` gets wrapped.
      final cleaned = msg.startsWith('Exception: ') ? msg.substring('Exception: '.length) : msg;
      setState(() => _error = cleaned.isNotEmpty ? cleaned : 'Não foi possível entrar. Tente novamente.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            final minHeight = (viewport.maxHeight - (AppSpacing.lg * 2)).clamp(0.0, double.infinity);
            return SingleChildScrollView(
              padding: AppSpacing.paddingLg,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
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
                                Icon(Icons.lock_outline_rounded, color: cs.primary),
                                const SizedBox(width: AppSpacing.sm),
                                Text('Entrar', style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'Acesse com email e senha da sua empresa.',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            TextField(
                              controller: _emailCtrl,
                              keyboardType: TextInputType.emailAddress,
                              textCapitalization: TextCapitalization.none,
                              autocorrect: false,
                              enableSuggestions: false,
                              textInputAction: TextInputAction.next,
                              onTap: _clearErrorOnUserInteraction,
                              onChanged: (_) => _clearErrorOnUserInteraction(),
                              decoration: InputDecoration(
                                labelText: 'Email',
                                prefixIcon: Icon(Icons.alternate_email_rounded, color: cs.onSurfaceVariant),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.md),
                            TextField(
                              controller: _passwordCtrl,
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              onTap: _clearErrorOnUserInteraction,
                              onChanged: (_) => _clearErrorOnUserInteraction(),
                              onSubmitted: (_) => _isLoading ? null : _login(),
                              decoration: InputDecoration(
                                labelText: 'Senha',
                                prefixIcon: Icon(Icons.password_rounded, color: cs.onSurfaceVariant),
                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword ? 'Mostrar senha' : 'Ocultar senha',
                                  onPressed: _isLoading
                                      ? null
                                      : () => setState(() => _obscurePassword = !_obscurePassword),
                                  style: IconButton.styleFrom(
                                    splashFactory: NoSplash.splashFactory,
                                    highlightColor: Colors.transparent,
                                  ),
                                  icon: Icon(
                                    // Icon represents the current state (not the action):
                                    // slashed = hidden, unslashed = visible.
                                    _obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
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
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _isLoading ? null : _login,
                                icon: _isLoading
                                    ? SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary),
                                      )
                                    : Icon(Icons.login_rounded, color: cs.onPrimary),
                                label: Text(
                                  _isLoading ? 'Entrando…' : 'Entrar',
                                  style: TextStyle(color: cs.onPrimary),
                                ),
                              ),
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
