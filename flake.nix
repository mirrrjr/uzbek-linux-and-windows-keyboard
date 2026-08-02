{
  description = "Custom uzbek keyboard layout with support for typographic letters";

  outputs = {self}: {
    nixosModules.module = import ./module.nix;
    nixosModules.default = import ./module.nix;
  };
}
