defmodule Authmk.MixProject do
  use Mix.Project

  @source_url "https://github.com/MudrockSoftware/authmk"
  @homepage_url "https://authmk.com"

  def project do
    [
      app: :authmk,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "An extensible, plugin-based authentication framework for Elixir, inspired by Better Auth.",
      package: package(),
      source_url: @source_url,
      homepage_url: @homepage_url,
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Website" => @homepage_url, "GitHub" => @source_url}
    ]
  end
end
