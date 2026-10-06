"""The Hex closure, as a single module extension.

    hex_ext = use_extension("//third_party/hex:extensions.bzl", "hex")
    use_repo(hex_ext, "hexpm")

Depend on a package as `@hexpm//:<app>` -- for example `@hexpm//:ecto`.
"""

load("@rules_erlang//bzlmod:hex_packages.bzl", "hex_packages_extension", "hex_pkg")
load(":hex_packages.bzl", "HEX_PACKAGES")

def _stub(app):
    return Label("//third_party/hex:" + app + ".BUILD")

hex = hex_packages_extension(
    packages = [
        hex_pkg(
            name = app,
            package_name = hex_name,
            version = version,
            sha256 = sha256,
            build_file = _stub(app),
        )
        for (app, hex_name, version, sha256) in HEX_PACKAGES
    ],
)
