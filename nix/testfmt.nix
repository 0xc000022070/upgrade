{ lib, buildGoModule }:

buildGoModule {
  pname = "testfmt";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../tool/testfmt;
    fileset = lib.fileset.fileFilter (file: file.hasExt "go" || file.name == "go.mod") ../tool/testfmt;
  };

  vendorHash = null;

  meta = {
    description = "Progress and failure output for `flutter test --reporter json`";
    mainProgram = "testfmt";
  };
}
