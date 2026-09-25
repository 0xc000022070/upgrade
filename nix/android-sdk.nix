{ androidenv }:

androidenv.composeAndroidPackages {
  cmdLineToolsVersion = "22.0";
  platformToolsVersion = "37.0.1";
  platformVersions = [
    "35"
    "36"
    "37.0"
  ];
  buildToolsVersions = [
    "35.0.1"
    "36.0.0"
    "37.0.0"
  ];
  includeNDK = true;
  ndkVersions = [ "28.2.13676358" ];
  # AGP installs its own CMake for externalNativeBuild; 3.22.1 is its
  # default and must be present, since the store SDK cannot grow one.
  cmakeVersions = [
    "3.22.1"
    "3.31.6"
  ];
  includeEmulator = false;
  includeSystemImages = false;
  extraLicenses = [
    "android-sdk-preview-license"
    "android-sdk-arm-dbt-license"
    "android-googletv-license"
    "android-googlexr-license"
    "google-gdk-license"
    "intel-android-extra-license"
    "intel-android-sysimage-license"
    "mips-android-sysimage-license"
    "microxr-sysimage-license"
  ];
}
