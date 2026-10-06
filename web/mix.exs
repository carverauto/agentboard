defmodule Agentboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :agentboard,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: ["lib"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        agentboard: [include_executables_for: [:unix], steps: [&digest_assets/1, :assemble]]
      ],
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def application do
    [mod: {Agentboard.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  # Runs in the remote release assembler for both Bazel and Docker. Phoenix owns
  # fingerprinting; normalize only wall-clock metadata for reproducible archives.
  defp digest_assets(release) do
    static = Path.join(Mix.Project.app_path(), "priv/static")
    :ok = Phoenix.Digester.compile(static, static, true)
    path = Path.join(static, "cache_manifest.json")
    manifest = Jason.decode!(File.read!(path))

    manifest =
      update_in(manifest["digests"], fn digests ->
        Map.new(digests, fn {name, metadata} -> {name, Map.put(metadata, "mtime", 0)} end)
      end)

    File.write!(path, Jason.encode!(manifest))
    release
  end

  defp deps do
    [
      {:ash, "== 3.34.3"},
      {:ash_postgres, "== 2.14.2"},
      {:ash_phoenix, "== 2.3.25"},
      {:ash_events, "== 0.8.2"},
      {:ash_paper_trail, "== 0.7.0"},
      {:ash_oban, "== 0.8.14"},
      {:oban, "== 2.24.1"},
      {:simple_sat, "== 0.1.4"},
      {:castore, "== 1.0.21"},
      {:bandit, "== 1.12.5"},
      {:ecto_sql, "== 3.14.0"},
      {:jason, "== 1.4.5"},
      {:phoenix, "== 1.8.13"},
      {:phoenix_ecto, "== 4.7.0"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_view, "== 1.1.33"},
      {:postgrex, "== 0.22.4"}
    ]
  end
end

