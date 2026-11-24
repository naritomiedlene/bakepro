import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/number_parsing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class PrecoVendaProdutoPage extends StatefulWidget {
  const PrecoVendaProdutoPage({super.key, required this.produtoId, required this.nome, required this.percentualLucro, required this.custoProdUn, required this.despesaFixaUn, required this.despesaVarUn, required this.valorVendaInicial});

  final int produtoId;
  final String nome;
  final double percentualLucro;
  final double custoProdUn;
  final double despesaFixaUn;
  final double despesaVarUn;
  final double? valorVendaInicial;

  @override
  State<PrecoVendaProdutoPage> createState() => _PrecoVendaProdutoPageState();
}

class _PrecoVendaProdutoPageState extends State<PrecoVendaProdutoPage> {
  late final TextEditingController _controller;
  bool _saving = false;

  double get _precoVendaCalculado {
    final base = widget.custoProdUn + widget.despesaFixaUn + widget.despesaVarUn;
    return base * ((widget.percentualLucro / 100.0) + 1.0);
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.valorVendaInicial == null ? '' : formatPtBrMoney(widget.valorVendaInicial!));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _controller.text.trim();
    final parsed = raw.isEmpty ? null : parsePtBrNumber(raw);
    if (raw.isNotEmpty && (parsed == null || parsed.isNaN || parsed.isInfinite)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe um valor numérico válido.')));
      return;
    }

    setState(() => _saving = true);
    try {
      await SupabaseConfig.client.from('produto').update({
        'valorvenda': parsed,
        // Coluna "timestamp" (sem fuso): gravar a data/hora local pura.
        'dataatualizacaovalorvenda': DateTime.now().toIso8601String(),
      }).eq('produtoid', widget.produtoId);
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      debugPrint('PrecoVendaProduto: save failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao salvar: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: AppSpacing.paddingLg + EdgeInsets.only(bottom: bottomInset),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(onPressed: _saving ? null : () => context.pop(false), icon: const Icon(Icons.arrow_back_rounded), tooltip: 'Voltar'),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary))
                        : const Icon(Icons.save_rounded),
                    label: Text(_saving ? 'Salvando...' : 'Salvar'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Preço de venda', style: theme.textTheme.headlineSmall),
              const SizedBox(height: AppSpacing.xs),
              Text(widget.nome, style: theme.textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: AppSpacing.md),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PriceRow(label: 'Preço de venda calculado - R\$/un.', value: formatPtBrCurrency(_precoVendaCalculado)),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _controller,
                        enabled: !_saving,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _saving ? null : _save(),
                        onTapOutside: (_) => FocusScope.of(context).unfocus(),
                        decoration: const InputDecoration(
                          labelText: 'Preço de venda definido - R\$/un.',
                          hintText: 'Ex.: 12,90',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Dica: deixe em branco para remover o preço definido e usar somente o calculado.',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700))),
          const SizedBox(width: 10),
          Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}
