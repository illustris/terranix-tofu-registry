{
	description = "openTofu registry";

	inputs = {
		nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
		registry = {
			url = "github:opentofu/registry/";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, registry }: {
		lib = nixpkgs.lib // {
			# translate go arch to nix arch
			archMap = json: {
				amd64 = "x86_64";
				arm64 = "aarch64";
			}.${json.arch} + "-${json.os}";
			# get subdirs for a given path
			getSubDirs = with nixpkgs.lib; p: pipe p [
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
		};

		tofu = with self.lib; {
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
					in nameValuePair
						namespace
						{
							${provider} = pipe "${p}/${n}" [
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
							];
						}
					))
				]))
				# flatten the list
				flatten
				# convert to attrset
				listToAttrs
			];
		};
	};
}
