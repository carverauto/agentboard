"""Match dependency compile-time Ash settings with web/config/config.exs.

Each Hex package compiles independently on RBE. Resource transformers and
compile_env reads must receive the same settings as the assembled release.
"""

HEX_COMPILE_ENV_CONFIG = [
    "config :ash, include_embedded_source_by_default?: false",
    "config :ash, default_string_length_count: :codepoints",
]
