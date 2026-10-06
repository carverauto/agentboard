load("@rules_elixir//:mix_app.bzl", "mix_app")

package(default_visibility = ["//visibility:public"])

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
    app_name = "ecto_sql",
    srcs = [":sources"],
    hdrs = glob(
        ["include/**/*.hrl"],
        allow_empty = True,
    ),
    deps = [
        "@hex_db_connection//:erlang_app",
        "@hex_decimal//:erlang_app",
        "@hex_ecto//:erlang_app",
        "@hex_postgrex//:erlang_app",
        "@hex_telemetry//:erlang_app",
        "@rules_elixir//elixir",
    ],
)
