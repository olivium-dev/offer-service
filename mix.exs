defmodule OfferService.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :offer_service,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        flags: [:error_handling, :unknown, :unmatched_returns, :extra_return]
      ],
      releases: [
        offer_service: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent],
          # CRITICAL: lets runtime.exs configure Repo url/pool_size without compile-time match
          validate_compile_env: false,
          steps: [:assemble, :tar]   # :tar produces a .tar.gz alongside the dir
        ]
      ]
    ]
  end

  def application do
    [
      mod: {OfferService.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.json": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.18"},
      {:phoenix_view, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.7"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:opentelemetry_api, "~> 1.3"},
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.7"},
      {:opentelemetry_phoenix, "~> 1.2"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:req, "~> 0.5"},
      {:prom_ex, "~> 1.11"},
      {:oban, "~> 2.18"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
