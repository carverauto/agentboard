load("@rules_elixir//:mix_app.bzl", "mix_app")
package(default_visibility = ["//visibility:public"])
mix_app(
    name = "erlang_app",
    app_name = "mint_web_socket",
    srcs = glob(["**/*"]),
    deps = ["@hex_mint//:erlang_app", "@rules_elixir//elixir"],
)
