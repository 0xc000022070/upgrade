import 'package:flutter/widgets.dart';

import '../../design/tokens.dart';

class SentTag extends StatelessWidget {
  const SentTag({super.key});

  @override
  Widget build(BuildContext context) =>
      Text('SENT', style: context.tokens.label);
}
