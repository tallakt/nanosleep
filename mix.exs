defmodule Nanosleep.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/tallakt/nanosleep"

  def project do
    [
      app: :nanosleep,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      description:
        "Sleeps shorter than a millisecond for the BEAM: a small C program, run as a port, " <>
          "that answers after the nanoseconds asked for.",
      package: package(),
      source_url: @source_url,
      docs: docs(),
      test_coverage: [summary: [threshold: 85]],
      dialyzer: [
        # Under _build: a priv directory here would be where the C program is built to.
        plt_core_path: "_build/plts",
        plt_local_path: "_build/plts",
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib c_src Makefile Makefile.win mix.exs .formatter.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE", "NOTICE"],
      source_ref: "v#{@version}"
    ]
  end

  def application, do: []

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
