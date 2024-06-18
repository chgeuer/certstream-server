defmodule Certstream.Mixfile do
  use Mix.Project

  def project do
    [
      app: :certstream,
      version: "1.6.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      releases: [
        app: [
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :observer, :wx, :runtime_tools],
      mod: {Certstream, []}
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 2.12"},
      # Unfortunately {:easy_ssl, "~> 1.3"} on hex.pm doesn't have the commit https://github.com/CaliDog/EasySSL/commit/87ece602a3510ad60b7bba1755b6a32d5eb1141b
      {:easy_ssl, github: "CaliDog/EasySSL", branch: "master"},
      {:req, "~> 0.5.0"},
      {:instruments, "~> 1.1"},
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
