import 'package:flutter/widgets.dart';

import 'package:upgrade/design/tokens.dart';

class SentTag extends StatelessWidget {
  const SentTag({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('SENT', style: context.tokens.label);
}

class PromptTag extends StatelessWidget {
  const PromptTag({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('PROMPT', style: context.tokens.label);
}
