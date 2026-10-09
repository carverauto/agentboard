load("@rules_elixir//:mix_app.bzl", "mix_app")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "sources",
    srcs = glob(["**/*"], allow_empty = True),
)

mix_app(
    name = "erlang_app",
    app_name = "jose",
    srcs = [":sources"],
    hdrs = glob(["include/**/*.hrl"], allow_empty = True),
    deps = ["@rules_elixir//elixir"],
)
