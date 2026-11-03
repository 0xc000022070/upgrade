{
  stdenvNoCC,
  fetchurl,
  dpkg,
  patchelf,
}:

let
  deb =
    path: sha256:
    fetchurl {
      url = "https://packages.termux.dev/apt/termux-main/pool/main/${path}";
      inherit sha256;
    };
in
stdenvNoCC.mkDerivation {
  pname = "proot-android";
  version = "5.1.107.102";

  srcs = [
    (deb "p/proot/proot_5.1.107.102_aarch64.deb" "10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030")
    (deb "libt/libtalloc/libtalloc_2.5.0_aarch64.deb" "556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7")
    (deb "liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb" "0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6")
  ];

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
