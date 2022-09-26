{ lib
, stdenvNoCC
, callPackage
, writeShellScript
, writeText
, srcOnly
, linkFarmFromDrvs
, symlinkJoin
, makeWrapper
, dotnetCorePackages
, dotnetPackages
, mkNugetSource
, mkNugetDeps
, nuget-to-nix
, cacert
, coreutils
}:

{ name ? "${args.pname}-${args.version}"
, pname ? name
, enableParallelBuilding ? true
, doCheck ? false
  # Flags to pass to `makeWrapper`. This is done to avoid double wrapping.
, makeWrapperArgs ? [ ]

  # Flags to pass to `dotnet restore`.
, dotnetRestoreFlags ? [ ]
  # Flags to pass to `dotnet build`.
, dotnetBuildFlags ? [ ]
  # Flags to pass to `dotnet test`, if running tests is enabled.
, dotnetTestFlags ? [ ]
  # Flags to pass to `dotnet install`.
, dotnetInstallFlags ? [ ]
  # Flags to pass to `dotnet pack`.
, dotnetPackFlags ? [ ]
  # Flags to pass to dotnet in all phases.
, dotnetFlags ? [ ]

  # The path to publish the project to. When unset, the directory "$out/lib/$pname" is used.
, installPath ? null
  # The binaries that should get installed to `$out/bin`, relative to `$out/lib/$pname/`. These get wrapped accordingly.
  # Unfortunately, dotnet has no method for doing this automatically.
  # If unset, all executables in the projects root will get installed. This may cause bloat!
, executables ? null
  # Packs a project as a `nupkg`, and installs it to `$out/share`. If set to `true`, the derivation can be used as a dependency for another dotnet project by adding it to `projectReferences`.
, packNupkg ? false
  # The packages project file, which contains instructions on how to compile it. This can be an array of multiple project files as well.
, projectFile ? null
  # The NuGet dependency file. This locks all NuGet dependency versions, as otherwise they cannot be deterministically fetched.
  # This can be generated by running the `passthru.fetch-deps` script.
, nugetDeps ? null
  # A list of derivations containing nupkg packages for local project references.
  # Referenced derivations can be built with `buildDotnetModule` with `packNupkg=true` flag.
  # Since we are sharing them as nugets they must be added to csproj/fsproj files as `PackageReference` as well.
  # For example, your project has a local dependency:
  #     <ProjectReference Include="../foo/bar.fsproj" />
  # To enable discovery through `projectReferences` you would need to add a line:
  #     <ProjectReference Include="../foo/bar.fsproj" />
  #     <PackageReference Include="bar" Version="*" Condition=" '$(ContinuousIntegrationBuild)'=='true' "/>
, projectReferences ? [ ]
  # Libraries that need to be available at runtime should be passed through this.
  # These get wrapped into `LD_LIBRARY_PATH`.
, runtimeDeps ? [ ]

  # Tests to disable. This gets passed to `dotnet test --filter "FullyQualifiedName!={}"`, to ensure compatibility with all frameworks.
  # See https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-test#filter-option-details for more details.
, disabledTests ? [ ]
  # The project file to run unit tests against. This is usually referenced in the regular project file, but sometimes it needs to be manually set.
  # It gets restored and build, but not installed. You may need to regenerate your nuget lockfile after setting this.
, testProjectFile ? ""

  # The type of build to perform. This is passed to `dotnet` with the `--configuration` flag. Possible values are `Release`, `Debug`, etc.
, buildType ? "Release"
  # If set to true, builds the application as a self-contained - removing the runtime dependency on dotnet
, selfContainedBuild ? false
  # The dotnet SDK to use.
, dotnet-sdk ? dotnetCorePackages.sdk_6_0
  # The dotnet runtime to use.
, dotnet-runtime ? dotnetCorePackages.runtime_6_0
  # The dotnet SDK to run tests against. This can differentiate from the SDK compiled against.
, dotnet-test-sdk ? dotnet-sdk
, ...
} @ args:

let
  inherit (callPackage ./hooks {
    inherit dotnet-sdk dotnet-test-sdk disabledTests nuget-source dotnet-runtime runtimeDeps buildType;
  }) dotnetConfigureHook dotnetBuildHook dotnetCheckHook dotnetInstallHook dotnetFixupHook;

  localDeps =
    if (projectReferences != [ ])
    then linkFarmFromDrvs "${name}-project-references" projectReferences
    else null;

  _nugetDeps =
    if (nugetDeps != null) then
      if lib.isDerivation nugetDeps
      then nugetDeps
      else mkNugetDeps { inherit name; nugetDeps = import nugetDeps; }
    else throw "Defining the `nugetDeps` attribute is required, as to lock the NuGet dependencies. This file can be generated by running the `passthru.fetch-deps` script.";

  # contains the actual package dependencies
  dependenciesSource = mkNugetSource {
    name = "${name}-dependencies-source";
    description = "A Nuget source with the dependencies for ${name}";
    deps = [ _nugetDeps ] ++ lib.optional (localDeps != null) localDeps;
  };

  # this contains all the nuget packages that are implictly referenced by the dotnet
  # build system. having them as separate deps allows us to avoid having to regenerate
  # a packages dependencies when the dotnet-sdk version changes
  sdkDeps = mkNugetDeps {
    name = "dotnet-sdk-${dotnet-sdk.version}-deps";
    nugetDeps = dotnet-sdk.passthru.packages;
  };

  sdkSource = mkNugetSource {
    name = "dotnet-sdk-${dotnet-sdk.version}-source";
    deps = [ sdkDeps ];
  };

  nuget-source = symlinkJoin {
    name = "${name}-nuget-source";
    paths = [ dependenciesSource sdkSource ];
  };
in
stdenvNoCC.mkDerivation (args // {
  nativeBuildInputs = args.nativeBuildInputs or [ ] ++ [
    dotnetConfigureHook
    dotnetBuildHook
    dotnetCheckHook
    dotnetInstallHook
    dotnetFixupHook

    cacert
    makeWrapper
    dotnet-sdk
  ];

  makeWrapperArgs = args.makeWrapperArgs or [ ] ++ [
    "--prefix LD_LIBRARY_PATH : ${dotnet-sdk.icu}/lib"
  ];

  # Stripping breaks the executable
  dontStrip = args.dontStrip or true;

  # gappsWrapperArgs gets included when wrapping for dotnet, as to avoid double wrapping
  dontWrapGApps = args.dontWrapGApps or true;

  passthru = {
    inherit nuget-source;

    fetch-deps =
      let
        # Because this list is rather long its put in its own store path to maintain readability of the generated script
        exclusions = writeText "nuget-package-exclusions" (lib.concatStringsSep "\n" (dotnet-sdk.passthru.packages { fetchNuGet = attrs: attrs.pname; }));

        # Derivations may set flags such as `--runtime <rid>` based on the host platform to avoid restoring/building nuget dependencies they dont have or dont need.
        # This introduces an issue; In this script we loop over all platforms from `meta` and add the RID flag for it, as to fetch all required dependencies.
        # The script would inherit the RID flag from the derivation based on the platform building the script, and set the flag for any iteration we do over the RIDs.
        # That causes conflicts. To circumvent it we remove all occurances of the flag.
        flags =
          let
            hasRid = flag: lib.any (v: v) (map (rid: lib.hasInfix rid flag) (lib.attrValues dotnet-sdk.runtimeIdentifierMap));
          in
          builtins.filter (flag: !(hasRid flag)) (dotnetFlags ++ dotnetRestoreFlags);

        runtimeIds = map (system: dotnet-sdk.systemToDotnetRid system) (args.meta.platforms or dotnet-sdk.meta.platforms);
      in
      writeShellScript "fetch-${pname}-deps" ''
        set -euo pipefail

        export PATH="${lib.makeBinPath [ coreutils dotnet-sdk nuget-to-nix ]}"

        for arg in "$@"; do
            case "$arg" in
                --keep-sources|-k)
                    keepSources=1
                    shift
                    ;;
                --help|-h)
                    echo "usage: $0 <output path> [--keep-sources] [--help]"
                    echo "    <output path>   The path to write the lockfile to. A temporary file is used if this is not set"
                    echo "    --keep-sources  Dont remove temporary directories upon exit, useful for debugging"
                    echo "    --help          Show this help message"
                    exit
                    ;;
            esac
        done

        export tmp=$(mktemp -td "${pname}-tmp-XXXXXX")
        HOME=$tmp/home

        exitTrap() {
            test -n "''${ranTrap-}" && return
            ranTrap=1

            if test -n "''${keepSources-}"; then
                echo -e "Path to the source: $tmp/src\nPath to the fake home: $tmp/home"
            else
                rm -rf "$tmp"
            fi

            # Since mktemp is used this will be empty if the script didnt succesfully complete
            ! test -s "$depsFile" && rm -rf "$depsFile"
        }

        trap exitTrap EXIT INT TERM

        dotnetRestore() {
            local -r project="''${1-}"
            local -r rid="$2"

            dotnet restore ''${project-} \
                -p:ContinuousIntegrationBuild=true \
                -p:Deterministic=true \
                --packages "$tmp/nuget_pkgs" \
                --runtime "$rid" \
                ${lib.optionalString (!enableParallelBuilding) "--disable-parallel"} \
                ${lib.optionalString (flags != []) (toString flags)}
        }

        declare -a projectFiles=( ${toString (lib.toList projectFile)} )
        declare -a testProjectFiles=( ${toString (lib.toList testProjectFile)} )

        export DOTNET_NOLOGO=1
        export DOTNET_CLI_TELEMETRY_OPTOUT=1

        depsFile=$(realpath "''${1:-$(mktemp -t "${pname}-deps-XXXXXX.nix")}")
        mkdir -p "$tmp/nuget_pkgs"

        storeSrc="${srcOnly args}"
        src=$tmp/src
        cp -rT "$storeSrc" "$src"
        chmod -R +w "$src"

        cd "$src"
        echo "Restoring project..."

        for rid in "${lib.concatStringsSep "\" \"" runtimeIds}"; do
            (( ''${#projectFiles[@]} == 0 )) && dotnetRestore "" "$rid"

            for project in ''${projectFiles[@]-} ''${testProjectFiles[@]-}; do
                dotnetRestore "$project" "$rid"
            done
        done

        echo "Succesfully restored project"

        echo "Writing lockfile..."
        echo -e "# This file was automatically generated by passthru.fetch-deps.\n# Please dont edit it manually, your changes might get overwritten!\n" > "$depsFile"
        nuget-to-nix "$tmp/nuget_pkgs" "${exclusions}" >> "$depsFile"
        echo "Succesfully wrote lockfile to $depsFile"
      '';
  } // args.passthru or { };

  meta = {
    platforms = dotnet-sdk.meta.platforms;
  } // args.meta or { };
})
