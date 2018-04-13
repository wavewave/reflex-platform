{ nixpkgsFunc ? import ./nixpkgs
, system ? builtins.currentSystem
, config ? {}
, enableLibraryProfiling ? false
, enableExposeAllUnfoldings ? true
, enableTraceReflexEvents ? false
, useFastWeak ? true
, useReflexOptimizer ? false
, useTextJSString ? true
, iosSdkVersion ? "10.2"
, iosSdkLocation ? "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS${iosSdkVersion}.sdk"
, iosSupportForce ? false
}:
let iosSupport =
      if system != "x86_64-darwin" then false
      else if iosSupportForce || builtins.pathExists iosSdkLocation then true
      else builtins.trace "Warning: No iOS sdk found at ${iosSdkLocation}; iOS support disabled.  To enable, either install a version of Xcode that provides that SDK or override the value of iosSdkVersion to match your installed version." false;
    globalOverlay = self: super: {
      all-cabal-hashes = fetchurl {
        url = "https://github.com/commercialhaskell/all-cabal-hashes/archive/f3ed6300a062de13303d4dd8b3a42b8bc2b02744.tar.gz";
        sha256 = "065388vlnd1f1ylwayn1336idx02ci43rscz2jslpxlshvq2z2y7";
      };
    };
    nixpkgs = nixpkgsFunc ({
      inherit system;
      overlays = [globalOverlay];
      config = {
        allowUnfree = true;
        allowBroken = true; # GHCJS is marked broken in 011c149ed5e5a336c3039f0b9d4303020cff1d86
        permittedInsecurePackages = [
          "webkitgtk-2.4.11"
        ];
        packageOverrides = pkgs: {
          webkitgtk = pkgs.webkitgtk218x;
          # cabal2nix's tests crash on 32-bit linux; see https://github.com/NixOS/cabal2nix/issues/272
          ${if system == "i686-linux" then "cabal2nix" else null} = pkgs.haskell.lib.dontCheck pkgs.cabal2nix;
        };
      } // config;
    });
    inherit (nixpkgs) fetchurl fetchgit fetchgitPrivate fetchFromGitHub;
    nixpkgsCross = {
      android = nixpkgs.lib.mapAttrs (_: args: if args == null then null else nixpkgsFunc args) rec {
        arm64 = {
          system = "x86_64-linux";
          overlays = [globalOverlay];
          crossSystem = {
            config = "aarch64-unknown-linux-android";
            arch = "arm64";
            libc = "bionic";
            withTLS = true;
            openssl.system = "linux-generic64";
            platform = nixpkgs.pkgs.platforms.aarch64-multiplatform;
          };
          config.allowUnfree = true;
        };
        arm64Impure = arm64 // {
          crossSystem = arm64.crossSystem // { useAndroidPrebuilt = true; };
        };
        armv7a = {
          system = "x86_64-linux";
          overlays = [globalOverlay];
          crossSystem = {
            config = "arm-unknown-linux-androideabi";
            arch = "armv7";
            libc = "bionic";
            withTLS = true;
            openssl.system = "linux-generic32";
            platform = nixpkgs.pkgs.platforms.armv7l-hf-multiplatform;
          };
          config.allowUnfree = true;
        };
        armv7aImpure = armv7a // {
          crossSystem = armv7a.crossSystem // { useAndroidPrebuilt = true; };
        };
      };
      ios =
        let config = {
              allowUnfree = true;
              packageOverrides = p: {
                darwin = p.darwin // {
                  ios-cross = p.darwin.ios-cross.override {
                    # Depending on where ghcHEAD is in your nixpkgs checkout, you may need llvm 39 here instead
                    inherit (p.llvmPackages_39) llvm clang;
                  };
                };
                buildPackages = p.buildPackages // {
                  osx_sdk = p.buildPackages.callPackage ({ stdenv }:
                    let version = "10";
                    in stdenv.mkDerivation rec {
                    name = "iOS.sdk";

                    src = p.stdenv.cc.sdk;

                    unpackPhase    = "true";
                    configurePhase = "true";
                    buildPhase     = "true";
                    target_prefix = stdenv.lib.replaceStrings ["-"] ["_"] p.targetPlatform.config;
                    setupHook = ./setup-hook-ios.sh;

                    installPhase = ''
                      mkdir -p $out/
                      echo "Source is: $src"
                      cp -r $src/* $out/
                    '';

                    meta = with stdenv.lib; {
                      description = "The IOS OS ${version} SDK";
                      maintainers = with maintainers; [ copumpkin ];
                      platforms   = platforms.darwin;
                      license     = licenses.unfree;
                    };
                  }) {};
                };
              };
            };
        in nixpkgs.lib.mapAttrs (_: args: if args == null then null else nixpkgsFunc args) {
        simulator64 = {
          system = "x86_64-darwin";
          overlays = [globalOverlay];
          crossSystem = {
            useIosPrebuilt = true;
            # You can change config/arch/isiPhoneSimulator depending on your target:
            # aarch64-apple-darwin14 | arm64  | false
            # arm-apple-darwin10     | armv7  | false
            # i386-apple-darwin11    | i386   | true
            # x86_64-apple-darwin14  | x86_64 | true
            config = "x86_64-apple-darwin14";
            arch = "x86_64";
            isiPhoneSimulator = true;
            sdkVer = iosSdkVersion;
            useiOSCross = true;
            openssl.system = "darwin64-x86_64-cc";
            libc = "libSystem";
          };
          inherit config;
        };
        arm64 = {
          system = "x86_64-darwin";
          overlays = [globalOverlay];
          crossSystem = {
            useIosPrebuilt = true;
            # You can change config/arch/isiPhoneSimulator depending on your target:
            # aarch64-apple-darwin14 | arm64  | false
            # arm-apple-darwin10     | armv7  | false
            # i386-apple-darwin11    | i386   | true
            # x86_64-apple-darwin14  | x86_64 | true
            config = "aarch64-apple-darwin14";
            arch = "arm64";
            isiPhoneSimulator = false;
            sdkVer = iosSdkVersion;
            useiOSCross = true;
            openssl.system = "ios64-cross";
            libc = "libSystem";
          };
          inherit config;
        };
      };
    };
    haskellLib = nixpkgs.haskell.lib;
    filterGit = builtins.filterSource (path: type: !(builtins.any (x: x == baseNameOf path) [".git" "tags" "TAGS" "dist"]));
    # Retrieve source that is controlled by the hack-* scripts; it may be either a stub or a checked-out git repo
    hackGet = p:
      if builtins.pathExists (p + "/git.json") then (
        let gitArgs = builtins.fromJSON (builtins.readFile (p + "/git.json"));
        in if builtins.elem "@" (nixpkgs.lib.stringToCharacters gitArgs.url)
        then fetchgitPrivate gitArgs
        else fetchgit gitArgs)
      else if builtins.pathExists (p + "/github.json") then fetchFromGitHub (builtins.fromJSON (builtins.readFile (p + "/github.json")))
      else {
        name = baseNameOf p;
        outPath = filterGit p;
      };
    # All imports of sources need to go here, so that they can be explicitly cached
    sources = {
      ghcjs-boot = hackGet ./ghcjs-boot;
      shims = hackGet ./shims;
      ghcjs = hackGet ./ghcjs;
    };
    inherit (nixpkgs.stdenv.lib) optional optionals;
    optionalExtension = cond: overlay: if cond then overlay else _: _: {};
    applyPatch = patch: src: nixpkgs.runCommand "applyPatch" {
      inherit src patch;
    } ''
      cp -r "$src" "$out"

      cd "$out"
      chmod -R +w .
      patch -p1 <"$patch"
    '';
in with haskellLib;
let overrideCabal = pkg: f: if pkg == null then null else haskellLib.overrideCabal pkg f;
    replaceSrc = pkg: src: version: overrideCabal pkg (drv: {
      inherit src version;
      sha256 = null;
      revision = null;
      editedCabalFile = null;
    });
    combineOverrides = old: new: (old // new) // {
      overrides = nixpkgs.lib.composeExtensions old.overrides new.overrides;
    };
    makeRecursivelyOverridable = x: old: x.override old // {
      override = new: makeRecursivelyOverridable x (combineOverrides old new);
    };
    foreignLibSmuggleHeaders = pkg: overrideCabal pkg (drv: {
      postInstall = ''
        cd dist/build/${pkg.pname}/${pkg.pname}-tmp
        for header in $(find . | grep '\.h'$); do
          local dest_dir=$out/include/$(dirname "$header")
          mkdir -p "$dest_dir"
          cp "$header" "$dest_dir"
        done
      '';
    });
    cabal2nixResult = src: builtins.trace "cabal2nixResult is deprecated; use ghc.haskellSrc2nix or ghc.callCabal2nix instead" (ghc.haskellSrc2nix {
      name = "for-unknown-package";
      src = "file://${src}";
      sha256 = null;
    });
    addReflexTraceEventsFlag = if enableTraceReflexEvents
      then drv: appendConfigureFlag drv "-fdebug-trace-events"
      else drv: drv;
    addFastWeakFlag = if useFastWeak
      then drv: enableCabalFlag drv "fast-weak"
      else drv: drv;
    extendHaskellPackages = haskellPackages: makeRecursivelyOverridable haskellPackages {
      overrides = self: super:
        let reflexDom = import (hackGet ./reflex-dom) self nixpkgs;
            jsaddlePkgs = import (hackGet ./jsaddle) self;
            gargoylePkgs = self.callPackage (hackGet ./gargoyle) self;
            ghcjsDom = import (hackGet ./ghcjs-dom) self;
            addReflexOptimizerFlag = if useReflexOptimizer && (self.ghc.cross or null) == null
              then drv: appendConfigureFlag drv "-fuse-reflex-optimizer"
              else drv: drv;
        in {

        vector = doJailbreak super.vector;
        these = doJailbreak super.these;
        aeson-compat = doJailbreak super.aeson-compat;
        timezone-series = self.callCabal2nix "timezone-series" (fetchFromGitHub {
          owner = "ygale";
          repo = "timezone-series";
          rev = "9f42baf542c54ad554bd53582819eaa454ed633d";
          sha256 = "1axrx8lziwi6pixws4lq3yz871vxi81rib6cpdl62xb5bh9y03j6";
        }) {};
        timezone-olson = self.callCabal2nix "timezone-olson" (fetchFromGitHub {
          owner = "ygale";
          repo = "timezone-olson";
          rev = "aecec86be48580f23145ffb3bf12a4ae191d12d3";
          sha256 = "1xxbwb8z27qbcscbg5qdyzlc2czg5i3b0y04s9h36hfcb07hasnz";
        }) {};
        quickcheck-instances = doJailbreak super.quickcheck-instances;

        gtk2hs-buildtools = doJailbreak super.gtk2hs-buildtools;

        ########################################################################
        # Reflex packages
        ########################################################################
        reflex = addFastWeakFlag (addReflexTraceEventsFlag (addReflexOptimizerFlag (self.callPackage (hackGet ./reflex) {})));
        reflex-dom = addReflexOptimizerFlag (doJailbreak reflexDom.reflex-dom);
        reflex-dom-core = addReflexOptimizerFlag (doJailbreak reflexDom.reflex-dom-core);
        reflex-todomvc = self.callPackage (hackGet ./reflex-todomvc) {};
        reflex-aeson-orphans = self.callPackage (hackGet ./reflex-aeson-orphans) {};
        haven = doJailbreak (self.callHackage "haven" "0.2.0.0" {});
        ghci-ghcjs = self.callCabal2nix "ghci-ghcjs" (self.ghcjsSrc + "/lib/ghci-ghcjs") {};
        ghcjs-th = self.callCabal2nix "ghcjs-th" (self.ghcjsSrc + "/lib/ghcjs-th") {};
        template-haskell-ghcjs = self.callCabal2nix "template-haskell-ghcjs" (self.ghcjsSrc + "/lib/template-haskell-ghcjs") {};
        ghc-api-ghcjs = overrideCabal (self.callCabal2nix "ghc-api-ghcjs" (self.ghcjsSrc + "/lib/ghc-api-ghcjs") {}) (drv: {
          libraryToolDepends = (drv.libraryToolDepends or []) ++ [
            ghc8_2_2.alex
            ghc8_2_2.happy
          ];
        });
        haddock-api-ghcjs = self.callCabal2nix "haddock-api-ghcjs" (self.ghcjsSrc + "/lib/haddock-api-ghcjs") {};
        haddock-library-ghcjs = dontHaddock (self.callCabal2nix "haddock-library-ghcjs" (self.ghcjsSrc + "/lib/haddock-library-ghcjs") {});
        ghcjsSrc = nixpkgs.runCommand "ghcjs-src" {
          nativeBuildInputs = [
            nixpkgs.perl
            nixpkgs.autoconf
            nixpkgs.automake
            self.ghc
            self.happy
            self.alex
            self.cabal-install
          ];
          buildInputs = [
            nixpkgs.gmp
          ];
          src = (if useFastWeak then applyPatch ./fast-weak.patch else id) (hackGet ./ghcjs);
        } ''
          cp -r "$src" "$out"
          chmod -R +w "$out"
          cd "$out/ghc"

          #TODO: Find a better way to avoid impure version numbers
          sed -i 's/RELEASE=NO/RELEASE=YES/' configure.ac

          patchShebangs .
          ./boot
          ./configure
          make -j"$NIX_BUILD_CORES"
          cd ..
          patchShebangs utils
          ./utils/makePackages.sh copy
        '';
        ghcjs-test = appendConfigureFlag (doJailbreak (dontHaddock (self.callCabal2nix "ghcjs" self.ghcjsSrc {}))) "-fno-wrapper-install";
        #TODO: makePackages.sh creates impurity by using the ghc development version, which is based on the current time
        ghcjs-booted = nixpkgs.runCommand "ghcjs-${self.ghcjs-test.version}" {
          #TODO: Add hscolour, haddock, and hoogle
          nativeBuildInputs = [
            self.ghc
            self.cabal-install
            nixpkgs.nodejs
            nixpkgs.pkgconfig #TODO: This doesn't seem to actually do anything
          ];
          buildInputs = [
            nixpkgs.gmp #TODO: Remove once ghcjs's integer-gmp stops depending on gmp.h
          ];
          inherit (self) ghcjsSrc;
          ghcjs = self.ghcjs-test;
          passthru = {
            bootPkgs = ghc8_2_2;
            isGhcjs = true;
            stage1Packages = []; #TODO
            mkStage2 = _: {};
            version = self.ghcjs-test.version;
            meta.platforms = self.ghc.meta.platforms;
            targetPrefix = "";
            haskellCompilerName = "ghcjs";
            socket-io = nixpkgs.nodePackages."socket.io";
          };
        } ''
          mkdir -p "$out/bin"
          for x in $(ls "$ghcjsSrc"/data/bin | sed -n 's/\(.*\)\.sh/\1/p') ; do
            sed -e "s|{topdir}|$out/lib/${self.ghcjs-test.name}|" -e "s|{libexecdir}|$ghcjs/bin|" <"$ghcjsSrc/data/bin/$x.sh" >"$out/bin/$x"
            chmod +x "$out/bin/$x"
          done
          for x in $(ls "$ghcjs/bin") ; do
            if [ ! -f "$out/bin/$x" ] ; then
              ln -s "$ghcjs/bin/$x" "$out/bin/$x"
            fi
          done
          PATH="$out/bin:$PATH"
          HOME="$out"
          "$ghcjs/bin/ghcjs-boot" -j "$NIX_BUILD_CORES"
        '';

        inherit (jsaddlePkgs) jsaddle-clib jsaddle-wkwebview jsaddle-webkit2gtk jsaddle-webkitgtk;
        jsaddle = if (self.ghc.isGhcjs or false)
          then overrideCabal jsaddlePkgs.jsaddle (drv: {
            libraryHaskellDepends = (drv.libraryHaskellDepends or []) ++ [self.ghcjs-base self.ghcjs-prim];
          })
          else jsaddlePkgs.jsaddle;
        jsaddle-warp = dontCheck jsaddlePkgs.jsaddle-warp;

        jsaddle-dom = overrideCabal (self.callPackage (hackGet ./jsaddle-dom) {}) (drv: {
          # On macOS, the jsaddle-dom build will run out of file handles the first time it runs
          preBuild = ''./setup build || true'';
        });

        inherit (ghcjsDom) ghcjs-dom-jsffi;

        # TODO: Fix this in Cabal
        # When building a package with no haskell files, cabal haddock shouldn't fail
        ghcjs-dom-jsaddle = dontHaddock ghcjsDom.ghcjs-dom-jsaddle;
        ghcjs-dom = dontHaddock ghcjsDom.ghcjs-dom;

        inherit (gargoylePkgs) gargoyle gargoyle-postgresql;

        ########################################################################
        # Tweaks
        ########################################################################
        # We can't use callHackage on haskell-gi-base, because it has a system
        # dependency that callHackage doesn't figure out
        haskell-gi-base = overrideCabal super.haskell-gi-base (drv: {
          version = "0.21.0";
          sha256 = "1vrz2vrmvsbahzsp1c06x4qmny5qhbrnz5ybzh5p8z1g3ji9z166";
          revision = null;
          editedCabalFile = null;
        });

        haskell-gi = self.callHackage "haskell-gi" "0.21.0" {};
        ghcjs-base-stub = dontHaddock super.ghcjs-base-stub;

        exception-transformers = doJailbreak super.exception-transformers;
        haskell-src-exts = self.callHackage "haskell-src-exts" "1.20.1" {};
        haskell-src-meta = self.callHackage "haskell-src-meta" "0.8.0.2" {};

        haskell-gi-overloading = super.haskell-gi-overloading_0_0;

        webkit2gtk3-javascriptcore = super.webkit2gtk3-javascriptcore.override {
          webkitgtk = nixpkgs.webkitgtk218x;
        };

        cabal-macosx = overrideCabal super.cabal-macosx (drv: {
          src = fetchFromGitHub {
            owner = "obsidiansystems";
            repo = "cabal-macosx";
            rev = "b1e22331ffa91d66da32763c0d581b5d9a61481b";
            sha256 = "1y2qk61ciflbxjm0b1ab3h9lk8cm7m6ln5ranpf1lg01z1qk28m8";
          };
          doCheck = false;
        });

        ########################################################################
        # Fixes to be upstreamed
        ########################################################################
        foundation = dontCheck super.foundation;
        MonadCatchIO-transformers = doJailbreak super.MonadCatchIO-transformers;
        blaze-builder-enumerator = doJailbreak super.blaze-builder-enumerator;
        process-extras = dontCheck super.process-extras;

        ########################################################################
        # Packages not in hackage
        ########################################################################
        servant-reflex = self.callCabal2nix "servant-reflex" (fetchFromGitHub {
          owner = "imalsogreg";
          repo = "servant-reflex";
          rev = "bd6e66fe00e131f8d1003201873258a5f3b06797";
          sha256 = "025y346jimh7ki8q3zrkh3xsx6ddc3zf95qxmbnpy1ww3h0i2wq4";
        }) {};
        concat = dontHaddock (dontCheck (self.callCabal2nix "concat" (fetchFromGitHub {
          owner = "conal";
          repo = "concat";
          rev = "24a4b8ccc883605ea2b0b4295460be2f8a245154";
          sha256 = "0mcwqzjk3f8qymmkbpa80l6mh6aa4vcyxky3gpwbnx19g721mj35";
        }) {}));

        superconstraints =
          # Remove override when assertion fails
          assert (super.superconstraints or null) == null;
          self.callPackage (self.haskellSrc2nix {
            name = "superconstraints";
            src = fetchurl {
              url = "https://hackage.haskell.org/package/superconstraints-0.0.1/superconstraints.cabal";
              sha256 = "0bgc8ldml3533522gp1x2bjiazllknslpl2rvdkd1k1zfdbh3g9m";
            };
            sha256 = "1gx9p9i5jli91dnvvrc30j04h1v2m3d71i8sxli6qrhplq5y63dk";
          }) {};
      } // (if enableLibraryProfiling then {
        mkDerivation = expr: super.mkDerivation (expr // { enableLibraryProfiling = true; });
      } else {});
    };
    haskellOverlays = import ./haskell-overlays {
      inherit
        haskellLib
        nixpkgs jdk fetchFromGitHub
        useReflexOptimizer
        hackGet;
      inherit (nixpkgs) lib;
    };
    ghcjsCompiler = ghc8_2_2.ghcjs-booted;
    ghcjsPackages = nixpkgs.callPackage (nixpkgs.path + "/pkgs/development/haskell-modules") {
      ghc = ghcjsCompiler;
      buildHaskellPackages = ghcjsCompiler.bootPkgs;
      compilerConfig = nixpkgs.callPackage (nixpkgs.path + "/pkgs/development/haskell-modules/configuration-ghc-7.10.x.nix") { inherit haskellLib; };
      packageSetConfig = nixpkgs.callPackage (nixpkgs.path + "/pkgs/development/haskell-modules/configuration-ghcjs.nix") { inherit haskellLib; };
      inherit haskellLib;
    };
#    TODO: Figure out why this approach doesn't work; it doesn't seem to evaluate our overridden ghc at all
#    ghcjsPackages = nixpkgs.haskell.packages.ghcjs.override {
#      ghc = builtins.trace "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ghcjsCompiler;
#    };
  ghc = ghc8_2_2;
  ghcjs = (extendHaskellPackages ghcjsPackages).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghcjs
      (optionalExtension useTextJSString haskellOverlays.textJSString)
    ];
  };
  ghcHEAD = (extendHaskellPackages nixpkgs.pkgs.haskell.packages.ghcHEAD).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-head
    ];
  };
  ghc8_2_2 = (extendHaskellPackages nixpkgs.pkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8_2_2
    ];
  };
  ghc8_0_2 = (extendHaskellPackages nixpkgs.pkgs.haskell.packages.ghc802).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8
    ];
  };
  ghc7 = (extendHaskellPackages nixpkgs.pkgs.haskell.packages.ghc7103).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-7
    ];
  };
  ghc7_8 = (extendHaskellPackages nixpkgs.pkgs.haskell.packages.ghc784).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-7_8
    ];
  };
  ghcAndroidArm64 = (extendHaskellPackages nixpkgsCross.android.arm64Impure.pkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8_2_2
      haskellOverlays.disableTemplateHaskell
      haskellOverlays.android
    ];
  };
  ghcAndroidArmv7a = (extendHaskellPackages nixpkgsCross.android.armv7aImpure.pkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8_2_2
      haskellOverlays.disableTemplateHaskell
      haskellOverlays.android
    ];
  };
  ghcIosSimulator64 = (extendHaskellPackages nixpkgsCross.ios.simulator64.pkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8_2_2
    ];
  };
  ghcIosArm64 = (extendHaskellPackages nixpkgsCross.ios.arm64.pkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8_2_2
      haskellOverlays.disableTemplateHaskell
      haskellOverlays.ios
    ];
  };
  ghcIosArmv7 = (extendHaskellPackages nixpkgsCross.ios.armv7.pkgs.haskell.packages.ghc822).override {
    overrides = nixpkgs.lib.foldr nixpkgs.lib.composeExtensions (_: _: {}) [
      (optionalExtension enableExposeAllUnfoldings haskellOverlays.exposeAllUnfoldings)
      haskellOverlays.ghc-8_2_2
      haskellOverlays.disableTemplateHaskell
      haskellOverlays.ios
    ];
  };
  #TODO: Separate debug and release APKs
  #TODO: Warn the user that the android app name can't include dashes
  android = androidWithHaskellPackages { inherit ghcAndroidArm64 ghcAndroidArmv7a; };
  androidWithHaskellPackages = { ghcAndroidArm64, ghcAndroidArmv7a }: import ./android {
    nixpkgs = nixpkgsFunc { system = "x86_64-linux"; };
    inherit nixpkgsCross ghcAndroidArm64 ghcAndroidArmv7a overrideCabal;
  };
  ios = iosWithHaskellPackages ghcIosArm64;
  iosWithHaskellPackages = ghcIosArm64: {
    buildApp = import ./ios {
      inherit ghcIosArm64;
      nixpkgs = nixpkgsFunc { system = "x86_64-darwin"; };
      inherit (nixpkgsCross.ios.arm64) libiconv;
    };
  };
in let this = rec {
  inherit nixpkgs
          nixpkgsCross
          overrideCabal
          hackGet
          extendHaskellPackages
          foreignLibSmuggleHeaders
          stage2Script
          ghc
          ghcHEAD
          ghc8_2_2
          ghc8_0_1
          ghc7
          ghc7_8
          ghcIosSimulator64
          ghcIosArm64
          ghcIosArmv7
          ghcAndroidArm64
          ghcAndroidArmv7a
          ghcjs
          android
          androidWithHaskellPackages
          ios
          iosWithHaskellPackages;
  androidReflexTodomvc = android.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    applicationId = "org.reflexfrp.todomvc";
    displayName = "Reflex TodoMVC";
  };
  iosReflexTodomvc = ios.buildApp {
    package = p: p.reflex-todomvc;
    executableName = "reflex-todomvc";
    bundleIdentifier = "org.reflexfrp.todomvc";
    bundleName = "Reflex TodoMVC";
  };
  setGhcLibdir = ghcLibdir: inputGhcjs:
    let libDir = "$out/lib/ghcjs-${inputGhcjs.version}";
        ghcLibdirLink = nixpkgs.stdenv.mkDerivation {
          name = "ghc_libdir";
          inherit ghcLibdir;
          buildCommand = ''
            mkdir -p ${libDir}
            echo "$ghcLibdir" > ${libDir}/ghc_libdir_override
          '';
        };
    in inputGhcjs // {
    outPath = nixpkgs.buildEnv {
      inherit (inputGhcjs) name;
      paths = [ inputGhcjs ghcLibdirLink ];
      postBuild = ''
        mv ${libDir}/ghc_libdir_override ${libDir}/ghc_libdir
      '';
    };
  };

  platforms = [
    "ghcjs"
    "ghc"
  ] #++ (optionals (system == "x86_64-linux") [
   # "ghcAndroidArm64"
   # "ghcAndroidArmv7a"
  #]) ++ (optionals iosSupport [
  #  "ghcIosArm64"
  #]);
  ;
  
  attrsToList = s: map (name: { inherit name; value = builtins.getAttr name s; }) (builtins.attrNames s);
  mapSet = f: s: builtins.listToAttrs (map ({name, value}: {
    inherit name;
    value = f value;
  }) (attrsToList s));
  mkSdist = pkg: pkg.override {
    mkDerivation = drv: ghc.mkDerivation (drv // {
      postConfigure = ''
        ./Setup sdist
        mkdir "$out"
        mv dist/*.tar.gz "$out/${drv.pname}-${drv.version}.tar.gz"
        exit 0
      '';
      doHaddock = false;
    });
  };
  sdists = mapSet mkSdist ghc;
  mkHackageDocs = pkg: pkg.override {
    mkDerivation = drv: ghc.mkDerivation (drv // {
      postConfigure = ''
        ./Setup haddock --hoogle --hyperlink-source --html --for-hackage --haddock-option=--built-in-themes
        cd dist/doc/html
        mkdir "$out"
        tar cz --format=ustar -f "$out/${drv.pname}-${drv.version}-docs.tar.gz" "${drv.pname}-${drv.version}-docs"
        exit 0
      '';
      doHaddock = false;
    });
  };
  hackageDocs = mapSet mkHackageDocs ghc;
  mkReleaseCandidate = pkg: nixpkgs.stdenv.mkDerivation (rec {
    name = pkg.name + "-rc";
    sdist = mkSdist pkg + "/${pkg.pname}-${pkg.version}.tar.gz";
    docs = mkHackageDocs pkg + "/${pkg.pname}-${pkg.version}-docs.tar.gz";

    builder = builtins.toFile "builder.sh" ''
      source $stdenv/setup

      mkdir "$out"
      echo -n "${pkg.pname}-${pkg.version}" >"$out/pkgname"
      ln -s "$sdist" "$docs" "$out"
    '';

    # 'checked' isn't used, but it is here so that the build will fail if tests fail
    checked = overrideCabal pkg (drv: {
      doCheck = true;
      src = sdist;
    });
  });
  releaseCandidates = mapSet mkReleaseCandidate ghc;

  androidDevTools = [
    ghc.haven
    nixpkgs.maven
    nixpkgs.androidsdk
  ];

  # Tools that are useful for development under both ghc and ghcjs
  generalDevTools = haskellPackages:
    let nativeHaskellPackages = ghc;
    in [
    nativeHaskellPackages.Cabal
    nativeHaskellPackages.cabal-install
    nativeHaskellPackages.ghcid
    nativeHaskellPackages.hasktags
    nativeHaskellPackages.hlint
    nixpkgs.cabal2nix
    nixpkgs.curl
    nixpkgs.nix-prefetch-scripts
    nixpkgs.nodejs
    nixpkgs.pkgconfig
    nixpkgs.closurecompiler
  ] ++ (optionals (!(haskellPackages.ghc.isGhcjs or false) && builtins.compareVersions haskellPackages.ghc.version "8.2" < 0) [
    # ghc-mod doesn't currently work on ghc 8.2.2; revisit when https://github.com/DanielG/ghc-mod/pull/911 is closed
    # When ghc-mod is included in the environment without being wrapped in justStaticExecutables, it prevents ghc-pkg from seeing the libraries we install
    (nixpkgs.haskell.lib.justStaticExecutables nativeHaskellPackages.ghc-mod)
    haskellPackages.hdevtools
  ]) ++ (if builtins.compareVersions haskellPackages.ghc.version "7.10" >= 0 then [
    nativeHaskellPackages.stylish-haskell # Recent stylish-haskell only builds with AMP in place
  ] else []) ++ optionals (system == "x86_64-linux") androidDevTools;

  nativeHaskellPackages = haskellPackages:
    if haskellPackages.isGhcjs or false
    then haskellPackages.ghc
    else haskellPackages;

  workOn = haskellPackages: package: (overrideCabal package (drv: {
    buildDepends = (drv.buildDepends or []) ++ generalDevTools (nativeHaskellPackages haskellPackages);
  })).env;

  workOnMulti' = { env, packageNames, tools ? _: [] }:
    let ghcEnv = env.ghc.withPackages (packageEnv: builtins.concatLists (map (n: (packageEnv.${n}.override { mkDerivation = x: { out = builtins.filter (p: builtins.all (nameToAvoid: (p.pname or "") != nameToAvoid) packageNames) ((x.buildDepends or []) ++ (x.libraryHaskellDepends or []) ++ (x.executableHaskellDepends or []) ++ (x.testHaskellDepends or [])); }; }).out) packageNames));
    in nixpkgs.runCommand "shell" (ghcEnv.ghcEnvVars // {
      buildInputs = [
        ghcEnv
      ] ++ generalDevTools env ++ tools env;
    }) "";

  workOnMulti = env: packageNames: workOnMulti' { inherit env packageNames; };

  # A simple derivation that just creates a file with the names of all of its inputs.  If built, it will have a runtime dependency on all of the given build inputs.
  pinBuildInputs = drvName: buildInputs: otherDeps: nixpkgs.runCommand drvName {
    buildCommand = ''
      mkdir "$out"
      echo "$propagatedBuildInputs $buildInputs $nativeBuildInputs $propagatedNativeBuildInputs $otherDeps" > "$out/deps"
    '';
    inherit buildInputs otherDeps;
  } "";

  # The systems that we want to build for on the current system
  cacheTargetSystems = [
    "x86_64-linux"
    "i686-linux"
    "x86_64-darwin"
  ];

  isSuffixOf = suffix: s:
    let suffixLen = builtins.stringLength suffix;
    in builtins.substring (builtins.stringLength s - suffixLen) suffixLen s == suffix;

  reflexEnv = platform:
    let haskellPackages = builtins.getAttr platform this;
        ghcWithStuff = if platform == "ghc" || platform == "ghcjs" then haskellPackages.ghcWithHoogle else haskellPackages.ghcWithPackages;
    in ghcWithStuff (p: import ./packages.nix { haskellPackages = p; inherit platform; });

  tryReflexPackages = generalDevTools ghc
    ++ builtins.map reflexEnv platforms
    # ++ optional iosSupport iosReflexTodomvc
    # ++ optional (system == "x86_64-linux") androidReflexTodomvc;
    ;
    
  demoVM = (import "${nixpkgs.path}/nixos" {
    configuration = {
      imports = [
        "${nixpkgs.path}/nixos/modules/virtualisation/virtualbox-image.nix"
        "${nixpkgs.path}/nixos/modules/profiles/demo.nix"
      ];
      environment.systemPackages = tryReflexPackages;
    };
  }).config.system.build.virtualBoxOVA;

  lib = haskellLib;
  inherit cabal2nixResult sources system iosSupport;
  project = args: import ./project this (args ({ pkgs = nixpkgs; } // this));
  tryReflexShell = pinBuildInputs ("shell-" + system) tryReflexPackages [];
  js-framework-benchmark-src = hackGet ./js-framework-benchmark;
}; in this
