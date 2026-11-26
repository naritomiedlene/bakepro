import 'dart:convert';
import 'dart:typed_data';

import 'package:bakepro/openai/openai_config.dart';
import 'package:bakepro/services/item_service.dart';
import 'package:bakepro/services/state/app_session_controller.dart';
import 'package:bakepro/supabase/supabase_config.dart';
import 'package:bakepro/theme.dart';
import 'package:bakepro/utils/picked_file_bytes.dart';
import 'package:bakepro/utils/web_file_input.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class CompraItemImportSheet extends StatefulWidget {
  const CompraItemImportSheet({super.key, required this.compraId});

  final int compraId;

  @override
  State<CompraItemImportSheet> createState() => _CompraItemImportSheetState();
}

class _CompraItemImportSheetState extends State<CompraItemImportSheet> {
  bool _loading = false;
  String? _error;
  List<ImportedCompraLine> _lines = const [];

  bool _loadingItems = true;
  List<Map<String, dynamic>> _itemOptions = const [];

  final _itemService = const ItemService();

  Future<PickedFileBytes?> _pickBytes({required FileType type, List<String>? allowedExtensions}) async {
    try {
      // Dreamflow Preview Web may not register MethodChannel plugins (file_picker/image_picker).
      // If `dart:html` is available, use a pure-web <input type="file"> picker.
      if (webFileInputAvailable) {
        final accept = _acceptForWeb(type: type, allowedExtensions: allowedExtensions);
        return pickWebFileBytes(accept: accept);
      }

      final result = await FilePicker.pickFiles(type: type, allowedExtensions: allowedExtensions, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) return null;
      final f = result.files.first;
      final bytes = f.bytes;
      if (bytes == null) return null;
      return PickedFileBytes(bytes: bytes, name: f.name, mimeType: f.extension);
    } on MissingPluginException catch (e, st) {
      debugPrint('FilePicker MissingPluginException: $e\n$st');
      rethrow;
    } catch (e, st) {
      debugPrint('FilePicker failed: $e\n$st');
      rethrow;
    }
  }

  String _acceptForWeb({required FileType type, List<String>? allowedExtensions}) {
    if (type == FileType.image) return 'image/*';
    if (type == FileType.custom && allowedExtensions != null && allowedExtensions.isNotEmpty) {
      return allowedExtensions.map((e) => e.startsWith('.') ? e : '.$e').join(',');
    }
    return '*/*';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadItemOptions();
    });
  }

  Future<void> _loadItemOptions() async {
    setState(() {
      _loadingItems = true;
      _error = null;
    });

    try {
      final session = context.read<AppSessionController>();
      final rows = await _itemService.listForCompraImport(session: session, tipoItemId: 1);
      if (!mounted) return;
      setState(() => _itemOptions = rows);
    } catch (e) {
      debugPrint('Load item options for import failed: $e');
      if (!mounted) return;
      setState(() => _error = 'Não foi possível carregar a lista de Itens (De/Para).');
    } finally {
      if (mounted) setState(() => _loadingItems = false);
    }
  }

  Future<void> _startImportFromFile() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _lines = const [];
    });

    try {
      final file = await _pickBytes(
        type: FileType.custom,
        allowedExtensions: const ['txt', 'csv', 'png', 'jpg', 'jpeg', 'webp'],
      );
      if (file == null) return;

      final bytes = file.bytes;
      final name = (file.name).toLowerCase();

      if (bytes.isEmpty) {
        setState(() => _error = 'Arquivo vazio.');
        return;
      }

      // If it's a text-like file, send as text. Otherwise, try as image.
      final isText = name.endsWith('.txt') || name.endsWith('.csv');
      final isImage = name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.webp');

      final lines = await OpenAiConfig.extractCompraItems(
        imageBytes: isImage ? bytes : null,
        textContent: isText ? utf8.decode(bytes, allowMalformed: true) : null,
      );
      if (!mounted) return;
      setState(() {
        _lines = lines;
        if (lines.isEmpty) _error = 'Não encontrei itens no arquivo. Tente uma foto mais nítida ou um CSV.';
      });
    } catch (e, st) {
      debugPrint('Import from file failed: $e\n$st');
      if (!mounted) return;
      if (e is MissingPluginException) {
        setState(
          () => _error =
              'O recurso de seleção de arquivo não está disponível neste ambiente (MissingPluginException).\n'
              'Se estiver usando o Preview Web, este é um problema de plugin/ambiente.\n'
              'Como alternativa, tente importar a partir de uma imagem no seu dispositivo (Android/iOS) ou envie um CSV/TXT.',
        );
        return;
      }

      setState(() => _error = kDebugMode ? 'Falha ao importar.\n$e' : 'Falha ao importar.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startImportFromCamera() async {
    if (webFileInputAvailable) {
      await _startImportFromWebCamera();
      return;
    }

    await _startImportFromImage(source: ImageSource.camera);
  }

  Future<void> _startImportFromGallery() async {
    if (webFileInputAvailable) {
      await _startImportFromWebGallery();
      return;
    }
    await _startImportFromImage(source: ImageSource.gallery);
  }

  Future<void> _startImportFromWebCamera() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _lines = const [];
    });

    try {
      final file = await pickWebFileBytes(accept: 'image/*', captureFromCamera: true);
      if (file == null) return;
      final bytes = file.bytes;
      if (bytes.isEmpty) {
        setState(() => _error = 'Arquivo de imagem vazio.');
        return;
      }

      final lines = await OpenAiConfig.extractCompraItems(imageBytes: bytes);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        if (lines.isEmpty) _error = 'Não encontrei itens na imagem. Tente recortar/centralizar a lista de itens.';
      });
    } catch (e, st) {
      debugPrint('Import from web camera failed: $e\n$st');
      if (!mounted) return;
      setState(() => _error = kDebugMode ? 'Falha ao importar.\n$e' : 'Falha ao importar.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startImportFromWebGallery() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _lines = const [];
    });

    try {
      // No Web (Preview), o image_picker pode lançar MissingPluginException. Usamos FilePicker.
      final file = await _pickBytes(type: FileType.image);
      if (file == null) return;
      final bytes = file.bytes;
      if (bytes.isEmpty) {
        setState(() => _error = 'Arquivo de imagem vazio.');
        return;
      }

      final lines = await OpenAiConfig.extractCompraItems(imageBytes: bytes);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        if (lines.isEmpty) _error = 'Não encontrei itens na imagem. Tente recortar/centralizar a lista de itens.';
      });
    } catch (e, st) {
      debugPrint('Import from web gallery failed: $e\n$st');
      if (!mounted) return;
      if (e is MissingPluginException) {
        setState(() => _error = 'O seletor de arquivos/imagens não está disponível neste ambiente (MissingPluginException).');
        return;
      }
      setState(() => _error = kDebugMode ? 'Falha ao importar.\n$e' : 'Falha ao importar.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startImportFromImage({required ImageSource source}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _lines = const [];
    });

    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();

      final lines = await OpenAiConfig.extractCompraItems(imageBytes: bytes);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        if (lines.isEmpty) _error = 'Não encontrei itens na imagem. Tente recortar/centralizar a lista de itens.';
      });
    } catch (e, st) {
      debugPrint('Import from image failed: $e\n$st');
      if (!mounted) return;
      if (e is MissingPluginException) {
        setState(
          () => _error =
              'O recurso de Galeria/Câmera não está disponível neste ambiente (MissingPluginException).\n'
              'No Preview Web, use “Arquivo”/“Galeria” (seletor) ou rode no Android/iOS.',
        );
        return;
      }
      setState(() => _error = kDebugMode ? 'Falha ao importar.\n$e' : 'Falha ao importar.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _process() async {
    if (_loading) return;
    if (_lines.isEmpty) {
      setState(() => _error = 'Nenhum item para processar.');
      return;
    }
    final missing = _lines.where((l) => l.itemId == null).length;
    if (missing > 0) {
      setState(() => _error = 'Defina o De/Para de todos os itens antes de processar.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = _lines.map((l) {
        final qtd = l.quantidade;
        final unit = l.custoUnitario;
        final total = (l.custoTotal == 0) ? (qtd * unit) : l.custoTotal;
        return <String, dynamic>{
          'compraid': widget.compraId,
          'itemid': l.itemId,
          'quantidade': qtd,
          'valorunitario': unit,
          'valortotalitem': total,
        };
      }).toList(growable: false);

      await SupabaseService.insertMultiple('compraitem', data);
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      debugPrint('Process import failed: $e');
      if (!mounted) return;
      setState(() => _error = kDebugMode ? 'Não foi possível processar.\n$e' : 'Não foi possível processar.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return Padding(
      padding: EdgeInsets.only(left: AppSpacing.md, right: AppSpacing.md, bottom: viewInsets.bottom + AppSpacing.md, top: AppSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(AppRadius.xl)),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Importar itens', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                  IconButton(onPressed: _loading ? null : () => context.pop(false), icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant), tooltip: 'Fechar'),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              if (_error != null) ...[
                _InlineError(message: _error!),
                const SizedBox(height: AppSpacing.md),
              ],
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _ActionChip(
                    icon: Icons.attach_file_rounded,
                    label: 'Arquivo',
                    onPressed: _loading ? null : _startImportFromFile,
                  ),
                  _ActionChip(
                    icon: Icons.photo_camera_rounded,
                    label: 'Câmera',
                    onPressed: _loading ? null : _startImportFromCamera,
                  ),
                  _ActionChip(
                    icon: Icons.photo_library_rounded,
                    label: 'Galeria',
                    onPressed: _loading ? null : _startImportFromGallery,
                  ),
                ],
              ),
              if (webFileInputAvailable) ...[
                const SizedBox(height: 6),
                Text(
                  'No Web, a seleção abre o seletor do navegador (pode pedir permissão).',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.25),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              if (_loadingItems)
                Row(
                  children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary)),
                    const SizedBox(width: AppSpacing.sm),
                    Text('Carregando Itens (De/Para)...', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              const SizedBox(height: AppSpacing.md),
              if (_loading) ...[
                const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: AppSpacing.lg), child: CircularProgressIndicator())),
              ] else if (_lines.isEmpty) ...[
                Text('Importe um arquivo/nota para listar os itens aqui.', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.25)),
              ] else ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _lines.length,
                    separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final line = _lines[index];
                      return _ImportedLineCard(
                        line: line,
                        itemOptions: _itemOptions,
                        onChanged: (newItemId) {
                          setState(() {
                            _lines[index].itemId = newItemId;
                          });
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _loading ? null : () => context.pop(false),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: (_loading || _loadingItems) ? null : _process,
                        icon: Icon(Icons.playlist_add_check_rounded, color: cs.onPrimary),
                        label: Text('Processar', style: TextStyle(color: cs.onPrimary)),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final bg = cs.surfaceContainerHighest;
    final fg = cs.onSurface;
    final iconColor = cs.onSurfaceVariant;

    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        disabledBackgroundColor: bg,
        disabledForegroundColor: fg.withValues(alpha: 0.55),
      ),
      icon: Icon(icon, color: onPressed == null ? iconColor.withValues(alpha: 0.55) : iconColor),
      label: Text(label, style: TextStyle(color: onPressed == null ? fg.withValues(alpha: 0.55) : fg)),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.error.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onErrorContainer, height: 1.25))),
          ],
        ),
      ),
    );
  }
}

class _ImportedLineCard extends StatelessWidget {
  const _ImportedLineCard({required this.line, required this.itemOptions, required this.onChanged});

  final ImportedCompraLine line;
  final List<Map<String, dynamic>> itemOptions;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final unit = _formatPtBrMoney(line.custoUnitario);
    final total = _formatPtBrMoney(line.custoTotal);
    final qtd = _formatPtBrMoney(line.quantidade);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.descricao, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 6,
              children: [
                _MiniPill(icon: Icons.inventory_2_outlined, label: 'Qtde: $qtd'),
                _MiniPill(icon: Icons.payments_outlined, label: 'Unit: R\$ $unit'),
                _MiniPill(icon: Icons.summarize_outlined, label: 'Total: R\$ $total'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<int>(
              // Menu de opções delimitado (fundo de card + cantos arredondados).
              dropdownColor: AppDropdownStyle.menuColor(context),
              borderRadius: AppDropdownStyle.menuRadius,
              style: AppDropdownStyle.menuTextStyle(context),
              value: line.itemId,
              isExpanded: true,
              icon: Icon(Icons.keyboard_arrow_down_rounded, color: cs.onSurfaceVariant),
              items: itemOptions
                  .map((r) {
                    final id = r['itemid'];
                    if (id is! num) return null;
                    final label = (r['nome'] ?? id).toString();
                    return DropdownMenuItem<int>(value: id.toInt(), child: Text(label, overflow: TextOverflow.ellipsis));
                  })
                  .whereType<DropdownMenuItem<int>>()
                  .toList(growable: false),
              onChanged: onChanged,
              decoration: const InputDecoration(labelText: 'De/Para *'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

String _formatPtBrMoney(dynamic v) {
  final n = _num(v) ?? 0;
  final fixed = n.toStringAsFixed(2);
  final parts = fixed.split('.');
  final intPart = parts[0];
  final decPart = parts.length > 1 ? parts[1] : '00';
  final withThousands = intPart.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '$withThousands,$decPart';
}

num? _num(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}
