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
      releases: [agentboard: [include_executables_for: [:unix]]],
      package: [licenses: ["Apache-2.0"]]
    ]
  end

  def application do
    [mod: {Agentboard.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp deps do
    [
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

