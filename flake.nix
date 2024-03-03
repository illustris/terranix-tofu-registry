{
	description = "openTofu registry";

	inputs = {
		nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
		registry = {
			url = "github:opentofu/registry/";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, registry }: with self.lib; {

		lib = nixpkgs.lib // {
			# translate go arch to nix arch
			archMap = json: {
				amd64 = "x86_64";
				arm64 = "aarch64";
			}.${json.arch} + "-${json.os}";
			# get subdirs for a given path
			getSubDirs = p: pipe p [
				# read contents of dir
				builtins.readDir
				# filter for dirs
				(filterAttrs (_: v: v=="directory"))
				# get names of dirs
				attrNames
				# append to base path
				(map (x: "${p}/${x}"))
			];
			# create derivation based on provider json
			fetchTofuProv = namespace: provider: version: json: nixpkgs.legacyPackages.${self.lib.archMap json}.callPackage (
				{ stdenv, fetchurl, unzip, ... }:
				stdenv.mkDerivation {
					pname = "${namespace}-${provider}";
					inherit version;
					src = fetchurl {
						url = json.download_url;
						sha256 = json.shasum;
					};
					buildInputs = [ unzip ];
					unpackPhase = let
						dst = "$out/${namespace}/${provider}/${version}/${json.os}_${json.arch}";
					in "mkdir -p ${dst}; cd ${dst}; unzip $src";
					meta = {
						inherit namespace provider;
						inherit (json) arch os;
					};
				}
			) {};

			getProvider = namespace: provider: version: system: let
				p = self.tofu.providers.${namespace}.${provider};
				v = (if version == null
				     then (latest p)
				     else version);
			in p.${v}.${system};

			latest = provider: pipe provider [
				attrNames
				(sort (a: b: builtins.compareVersions a b > 0))
				head
			];

			mkPluginsDirFromDRVs = { system, name ? "terranix.local", postBuild ? "", ... }: paths:
				nixpkgs.legacyPackages.${system}.symlinkJoin {
					inherit name postBuild paths;
				};

			# nix-repl> (lib.mkPluginsDir {system="x86_64-linux"; plugins = {bpg.proxmox = null; gxben.opnsense = "0.3.1";};})
			# «derivation /nix/store/n1y1sf226xm0y39cgvfyzs7769yqx86g-terranix.local.drv»
			mkPluginsDir = { system, name ? null , postBuild ? null , plugins }@args: pipe plugins [
				(mapAttrsRecursive (path: version: getProvider (head path) (last path) version system))
				(collect isDerivation)
				(mkPluginsDirFromDRVs args)
			];

			wrapTofuScript = {
				system
				, script
				, pluginsDrv
				, name ? "script"
				, init ? false
				, passArgsToScript ? true
				, tofuPackage ? null
				, x ? true
				, e ? false
				, cleanup ? true
				, tfConfig ? null
				, ...
			}: let
				pkgs = nixpkgs.legacyPackages.${system};
			in pkgs.writers.writeBash name ''
				${optionalString x "set -x"}
				${optionalString e "set -e"}
				DIR=$(mktemp -d)
				pushd $DIR
				mkdir -p terraform.d/plugins/
				# openTofu ignores symlinks at this level
				# linking it a level above or below might be a solution
				cp -r ${pluginsDrv} terraform.d/plugins/${pluginsDrv.name}
				${optionalString (tfConfig != null) "cp ${tfConfig} ./config.tf.json"}
				export PATH=${if tofuPackage == null then pkgs.opentofu else tofuPackage}/bin:$PATH
				${optionalString init "tofu init"}
				${script} ${optionalString passArgsToScript "$@"}
				popd
				${optionalString cleanup "rm -rf $DIR"}
			'';

			# the lib function you most likely want to use
			# apps.x86_64-linux.plan = {
			#   type = "app";
			#   program = toString (registry.lib.tofuScriptWithPlugins {
			#     system = "x86_64-linux";
			#     plugins.bpg.proxmox = null;
			#     script = "tofu plan";
			#     init = true;
			#     tfConfig = self.packages.x86_64-linux.tf;
			#   })
			# }
			tofuScriptWithPlugins = { system, plugins, ... }@args: self.lib.wrapTofuScript ({
				pluginsDrv = self.lib.mkPluginsDir { inherit system plugins; };
			} // args);
		};

		# This needs too much memory to evaluate
                # packages = pipe self.tofu [
                #       (collect isDerivation)
                #       (map (x: setAttrByPath [ x.system x.pname ] x))
                #       (take 1000)
                #       # (drop 100000)
                #       # traceVal
                #       (builtins.foldl' recursiveUpdate {})
                # ];

		tofu = {
			providers = pipe "${registry}/providers" [
				# get first level subdirs of providers path
				getSubDirs
				# get second level subdirs of providers path
				(map getSubDirs)
				# flatten nested list of paths
				flatten
				# generate list of jsons in each leaf dir
				# in the form of nameValuePairs
				(map (p: pipe p [
					# read contents of dir
					builtins.readDir
					# filter for jsons
					(filterAttrs (n: _: strings.hasSuffix ".json" n))
					# get names of files
					attrNames
					# make a nameValuePair attrset for each provider json
					(map (n: let
						# extract namespace from the path
						namespace = pipe p [
							(splitString "/")
							last
							builtins.unsafeDiscardStringContext
						];
						# extract provider name from json filename
						provider = strings.removeSuffix ".json" n;
					in {
						# create an attrset with path and val
						# this will be used to recursiveUpdate later
						# listToAttrs will overwrite multiple providers in the same namespace
						path = [
							namespace
							provider
						];
						val = (pipe "${p}/${n}" [
							# read json into attrset
							builtins.readFile
							builtins.fromJSON
							(attrByPath ["versions"] [])
							# each version+arch corresponds to a list element
							(map (x: nameValuePair x.version (pipe x.targets [
								# drop unsupported architectures
								(filter (x: elem x.arch ["arm64" "amd64"]))
								(filter (x: elem x.os ["darwin" "linux"]))
								# make attrsets with arch as key, and derivation as val
								(map (y: nameValuePair (archMap y) (fetchTofuProv namespace provider x.version y)))
								listToAttrs
							])))
							listToAttrs
						]);
					}))
				]))
				# flatten the list
				flatten
				# merge list of attrsets
				(map (x: setAttrByPath x.path x.val))
				(builtins.foldl'  recursiveUpdate {})
			];
		};
	};
}
