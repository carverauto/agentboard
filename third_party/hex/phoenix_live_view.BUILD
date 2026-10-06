load("@rules_elixir//:mix_app.bzl", "mix_app")

package(default_visibility = ["//visibility:public"])
filegroup(name = "browser_js", srcs = ["priv/static/phoenix_live_view.esm.js"])

#
# A Hex package is a Mix project. Compiling it with Mix rather than invoking elixirc from the
# execroot is what makes mix.exs (elixirc_paths, :compilers), Mix.Project introspection, and
# cwd-relative compile-time file reads work.
filegroup(
    name = "sources",
    srcs = glob(
        ["**/*"],
        allow_empty = True,
    ),
)

mix_app(
    name = "erlang_app",
    app_name = "phoenix_live_view",
    srcs = [":sources"],
    hdrs = glob(
        ["include/**/*.hrl"],
        allow_empty = True,
    ),
    deps = [
        "@hex_jason//:erlang_app",
        "@hex_phoenix//:erlang_app",
        "@hex_phoenix_html//:erlang_app",
        "@hex_phoenix_template//:erlang_app",
        "@hex_phoenix_view//:erlang_app",
        "@hex_plug//:erlang_app",
        "@hex_telemetry//:erlang_app",
        "@rules_elixir//elixir",
    ],
)
