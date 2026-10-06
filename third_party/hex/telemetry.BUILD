load("@rules_erlang//:erlang_app.bzl", "DEFAULT_ERLC_OPTS", "erlang_app")

package(default_visibility = ["//visibility:public"])

# Build tools: [:rebar3] -- compiled as an Erlang app, not via Mix.
erlang_app(
    app_name = "telemetry",
    # Keep warnings advisory, including if the upstream defaults change.
    erlc_opts = [opt for opt in DEFAULT_ERLC_OPTS if opt != "-Werror"],
)
