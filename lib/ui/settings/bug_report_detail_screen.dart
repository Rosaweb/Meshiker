import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../database/isar_service.dart';
import '../../models/pending_crash_report.dart';
import '../../utils/crash_reporting_service.dart';

/// Détail d'un rapport de crash premium en attente (spec-crash-reporting.md
/// §10) : compte à rebours, message libre autosauvegardé en brouillon,
/// envoi manuel immédiat ou suppression sans envoi.
class BugReportDetailScreen extends StatefulWidget {
  final PendingCrashReport report;

  const BugReportDetailScreen({super.key, required this.report});

  @override
  State<BugReportDetailScreen> createState() => _BugReportDetailScreenState();
}

class _BugReportDetailScreenState extends State<BugReportDetailScreen> {
  late final TextEditingController _messageController;
  Timer? _debounce;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController(text: widget.report.draftUserMessage ?? '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  void _onDraftChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      widget.report.draftUserMessage = value;
      await context.read<IsarService>().savePendingCrashReport(widget.report);
    });
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    _debounce?.cancel();
    widget.report.draftUserMessage = _messageController.text;
    final isar = context.read<IsarService>();
    await isar.savePendingCrashReport(widget.report);
    await CrashReportingService.deliver(widget.report, isar);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rapport envoyé, merci !')),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    _debounce?.cancel();
    await context.read<IsarService>().deletePendingCrashReport(widget.report.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm');
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Rapport de bug'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    report.exceptionType ?? 'Erreur inconnue',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Première occurrence : ${dateFormat.format(report.firstOccurredAt)}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  Text('Dernière occurrence : ${dateFormat.format(report.lastOccurredAt)}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  Text('Occurrences : ${report.occurrenceCount}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, color: Colors.orangeAccent, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        report.launchesRemaining > 0
                            ? 'Envoi automatique dans ${report.launchesRemaining} lancement${report.launchesRemaining > 1 ? 's' : ''} de l\'app'
                            : 'Envoi automatique imminent',
                        style: const TextStyle(color: Colors.orangeAccent, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                collapsedIconColor: Colors.white38,
                iconColor: Colors.greenAccent,
                backgroundColor: Colors.white.withValues(alpha: 0.05),
                collapsedBackgroundColor: Colors.white.withValues(alpha: 0.05),
                title: const Text('Détails techniques', style: TextStyle(color: Colors.white)),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: SelectableText(
                      _prettyJson(report.serializedEventJson),
                      style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('VOTRE MESSAGE (FACULTATIF)', style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              onChanged: _onDraftChanged,
              maxLines: 5,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Que faisiez-vous quand c\'est arrivé ?',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send),
              label: const Text('Envoyer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 45),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Supprimer'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(color: Colors.redAccent),
                minimumSize: const Size(double.infinity, 45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _prettyJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }
}
