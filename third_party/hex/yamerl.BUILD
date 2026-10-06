load("@rules_erlang//:erlang_app.bzl", "DEFAULT_ERLC_OPTS", "erlang_app")

package(default_visibility = ["//visibility:public"])

# Runtime dependency edges match the selected web/mix.lock closure.
# Build tools: [:rebar3] -- compiled as an Erlang app, not via Mix.
erlang_app(
    app_name = "yamerl",
    # rules_erlang defaults to -Werror, which is right for first-party code and wrong for a
    # third-party package we do not control: opentelemetry ships an exported-from-case warning
    # that has nothing to do with us, and failing on it means the dependency cannot be built.
    erlc_opts = [opt for opt in DEFAULT_ERLC_OPTS if opt != "-Werror"],
)
