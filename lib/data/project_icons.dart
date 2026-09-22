enum ProjectIconKind {
  bastion('BASTION'),
  echelon('ECHELON'),
  relay('RELAY'),
  cipher('CIPHER'),
  forge('FORGE'),
  wolf('WOLF'),
  raven('RAVEN'),
  viper('VIPER');

  const ProjectIconKind(this.label);

  final String label;

  String get asset => 'assets/project_emblems/$name.png';

  static ProjectIconKind? fromId(String? id) {
    for (final icon in values) {
      if (icon.name == id) return icon;
    }
    return null;
  }
}
