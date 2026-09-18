import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import 'syntax.dart';

/// Plain is null so the line's own colour shows through; punctuation is the muted text,
/// not a syntax colour, since it is furniture.
TextStyle? syntaxStyle(BuildContext context, SyntaxToken token) =>
    switch (token) {
      SyntaxToken.plain => null,
      SyntaxToken.punctuation => TextStyle(color: context.tokens.textMuted),
      SyntaxToken.keyword => TextStyle(color: context.tokens.syntax.keyword),
      SyntaxToken.type => TextStyle(color: context.tokens.syntax.type),
      SyntaxToken.string => TextStyle(color: context.tokens.syntax.string),
      SyntaxToken.number => TextStyle(color: context.tokens.syntax.number),
      SyntaxToken.comment => TextStyle(color: context.tokens.syntax.comment),
      SyntaxToken.annotation => TextStyle(
        color: context.tokens.syntax.annotation,
      ),
    };
