/*
  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

{
  description = "build123d + filewatcher123d Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        nixpkgs.follows = "nixpkgs";
      };
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
        uv2nix.follows = "uv2nix";
        nixpkgs.follows = "nixpkgs";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };
      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python313;

          runtimeLibs = with pkgs; [
            stdenv.cc.cc.lib
            expat
            libGL
            libGLU
            fontconfig
            freetype
            zlib
            libx11
            libxext
            libxi
            libxrender
            libsm
            libice
          ];

          patchWheel =
            pkg: extra:
            pkg.overrideAttrs (
              old:
              lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
                {
                  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.autoPatchelfHook ];
                  buildInputs = (old.buildInputs or [ ]) ++ runtimeLibs;
                }
                // extra
              )
            );

          fixBuildSystem =
            pkg: buildSystem:
            pkg.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ buildSystem;
            });

          pyprojectOverrides = final: prev: {
            filewatcher123d = fixBuildSystem prev.filewatcher123d (
              final.resolveBuildSystem { setuptools = [ ]; }
            );
            pyperclip = fixBuildSystem prev.pyperclip (final.resolveBuildSystem { setuptools = [ ]; });

            cadquery-vtk = patchWheel prev.cadquery-vtk { };
            cadquery-ocp = patchWheel prev.cadquery-ocp {
              preFixup = ''
                addAutoPatchelfSearchPath ${final.cadquery-vtk}/lib/python*/site-packages
              '';
            };
          };
        in
        (pkgs.callPackage pyproject-nix.build.packages { inherit python; }).overrideScope (
          lib.composeManyExtensions [
            pyproject-build-systems.overlays.wheel
            overlay
            pyprojectOverrides
          ]
        )
      );

    in
    {
      packages = forAllSystems (system: rec {
        default =
          (pythonSets.${system}.mkVirtualEnv "build123d-env" workspace.deps.default).overrideAttrs
            (old: {
              meta = (old.meta or { }) // {
                mainProgram = "fw123d"; # for `nix run`
              };
            });
        filewatcher123d = default;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          venv = pythonSets.${system}.mkVirtualEnv "build123d-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [
              venv
              pkgs.uv
            ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = "${venv}/bin/python";
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
              echo "build123d devShell ready (uv2nix). Try: fw123d myscript.py"
            '';
          };
        }
      );
    };
}
