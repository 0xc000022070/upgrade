{
  stdenvNoCC,
  fetchurl,
  dpkg,
  patchelf,
}:

# Termux deletes superseded debs from its pool, so every pin is also uploaded
# to this repo's proot-android-debs release by `just proot-bump`.
let
  pins = builtins.fromJSON (builtins.readFile ./proot-android.json);
  deb =
    name: pin:
    let
      file = "${name}_${pin.version}_aarch64.deb";
    in
    fetchurl {
      urls = [
        "https://packages.termux.dev/apt/termux-main/pool/main/${pin.pool}/${file}"
        "https://github.com/0xc000022070/upgrade/releases/download/proot-android-debs/${file}"
      ];
      inherit (pin) sha256;
    };
in
stdenvNoCC.mkDerivation {
  pname = "proot-android";
  inherit (pins.proot) version;

  srcs = builtins.attrValues (builtins.mapAttrs deb pins);

  nativeBuildInputs = [
    dpkg
    patchelf
  ];

  dontUnpack = true;
  dontFixup = true;

  installPhase = ''
    for src in $srcs; do dpkg-deb -x "$src" root; done
    prefix=root/data/data/com.termux/files/usr
    out_dir=$out/arm64-v8a
    mkdir -p "$out_dir"
    install -m755 "$prefix/bin/proot" "$out_dir/libproot.so"
    install -m755 "$prefix/libexec/proot/loader" "$out_dir/libproot-loader.so"
    install -m755 "$(readlink -f "$prefix/lib/libtalloc.so.2")" "$out_dir/libtalloc.so"
    install -m755 "$prefix/lib/libandroid-shmem.so" "$out_dir/libandroid-shmem.so"
    patchelf --replace-needed libtalloc.so.2 libtalloc.so "$out_dir/libproot.so"
    patchelf --set-soname libtalloc.so "$out_dir/libtalloc.so"
  '';
}
