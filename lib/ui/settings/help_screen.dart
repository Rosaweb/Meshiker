import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../assistant/assistant_prompt_bar.dart';

/// Écran "Aide" : affiche `docs/manuel_utilisateur.md` (embarqué en asset),
/// seule et unique source du contenu d'aide — également celle lue par
/// l'assistant IA (copie synchronisée dans
/// `supabase/functions/assistant-token/`), pour ne jamais avoir à
/// maintenir la même explication à deux endroits.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  late final Future<String> _manual = _loadManual();

  Future<String> _loadManual() async {
    final raw = await rootBundle.loadString('docs/manuel_utilisateur.md');
    // Les commentaires HTML sont des notes à destination des développeurs/de
    // l'assistant IA (cf. en-tête du fichier), pas du contenu pour
    // l'utilisateur final.
    return raw.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Aide'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
        ),
        // Section assistant ancrée en bas, hors du manuel scrollable : ne
        // scrolle pas avec le reste du contenu, cf. IA interface utilisateur.txt.
        body: Column(
          children: [
            Expanded(
              child: FutureBuilder<String>(
                future: _manual,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator(color: Colors.greenAccent));
                  }
                  return Markdown(
                    data: snapshot.data!,
                    padding: const EdgeInsets.all(16),
                    styleSheet: _manualStyleSheet(context),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: AssistantPromptBar(),
            ),
          ],
        ),
      ),
    );
  }

  MarkdownStyleSheet _manualStyleSheet(BuildContext context) {
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      h1: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
      h2: const TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.bold),
      h3: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
      p: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
      strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      em: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic),
      listBullet: const TextStyle(color: Colors.white70, fontSize: 13),
      blockquote: const TextStyle(color: Colors.white54, fontSize: 13, fontStyle: FontStyle.italic),
      blockquoteDecoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: const Border(left: BorderSide(color: Colors.greenAccent, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.all(12),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white10, width: 1)),
      ),
      code: const TextStyle(color: Colors.greenAccent, backgroundColor: Colors.transparent, fontSize: 13),
    );
  }
}
