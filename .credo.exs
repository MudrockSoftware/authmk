# Credo's defaults, with licensed/ checked too.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "licensed/", "test/", "config/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true
    }
  ]
}
