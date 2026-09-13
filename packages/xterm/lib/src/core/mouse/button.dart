enum TerminalMouseButton {
  left(id: 0),

  middle(id: 1),

  right(id: 2),

  wheelUp(id: 64 + 0, isWheel: true),

  wheelDown(id: 64 + 1, isWheel: true),

  wheelLeft(id: 64 + 2, isWheel: true),

  wheelRight(id: 64 + 3, isWheel: true),
  ;

  /// The id that is used to report a button press or release to the terminal.
  ///
  /// Wheel buttons 4-7 are encoded with bit 6 set (64) and the button number in
  /// the low two bits: 64 up, 65 down, 66 left, 67 right. Adding the raw button
  /// number on top of 64 instead (68-71) sets bit 2, which is the Shift
  /// modifier, so every wheel report would arrive as Shift+wheel. Dazzle
  /// patch; upstream fix is TerminalStudio/xterm.dart#238.
  final int id;

  /// Whether this button is a mouse wheel button.
  final bool isWheel;

  const TerminalMouseButton({required this.id, this.isWheel = false});
}
