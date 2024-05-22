defmodule Certstream.Mixfile do
  use Mix.Project

  def project do
    [
      app: :certstream,
      version: "1.6.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
      releases: [
        app: [
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:honeybadger, :logger],
      mod: {Certstream, []},
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 2.12"},
      {:easy_ssl, github: "CaliDog/EasySSL", branch: "master"},
      {:honeybadger, "~> 0.21"},
      {:httpoison, "~> 1.8"},
      {:instruments, "~> 1.1"},
      {:jason, "~> 1.4"},
      {:number, "~> 1.0"},
      {:pobox, "~> 1.2"},

      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end
end
