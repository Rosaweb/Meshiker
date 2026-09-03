import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../database/isar_service.dart';
import '../../models/pending_crash_report.dart';
import 'bug_report_detail_screen.dart';

/// Section "Rapport de bug" (spec-crash-reporting.md §9) : liste des
/// rapports de crash premium en attente d'envoi automatique ou de décision
/// utilisateur. N'est atteignable que si le toggle système est actif (voir
/// `AccountSettingsScreen`).
class BugReportListScreen extends StatefulWidget {
  const BugReportListScreen({super.key});

  @override
  State<BugReportListScreen> createState() => _BugReportListScreenState();
}

class _BugReportListScreenState extends State<BugReportListScreen> {
  late Future<List<PendingCrashReport>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = context.read<IsarService>().pendingCrashReports();
  }

  Future<void> _openDetail(PendingCrashReport report) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BugReportDetailScreen(report: report)),
    );
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
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
        body: FutureBuilder<List<PendingCrashReport>>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator(color: Colors.greenAccent));
            }
            final reports = snapshot.data!;
            if (reports.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Rien à signaler',
                    style: TextStyle(color: Colors.white38, fontSize: 16),
                  ),
                ),
              );
            }
            final dateFormat = DateFormat('dd/MM/yyyy HH:mm');
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: reports.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final report = reports[index];
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.bug_report, color: Colors.orangeAccent),
                    title: Text(
                      report.exceptionType ?? 'Erreur inconnue',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '${dateFormat.format(report.lastOccurredAt)}'
                      ' · ${report.occurrenceCount} occurrence${report.occurrenceCount > 1 ? 's' : ''}'
                      ' · envoi dans ${report.launchesRemaining} lancement${report.launchesRemaining > 1 ? 's' : ''}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white24),
                    onTap: () => _openDetail(report),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
