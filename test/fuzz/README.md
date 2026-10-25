Fuzz tests live here. Write them with `ExUnitProperties` (StreamData), tag the
module with `@moduletag :fuzz`, and run them with `mix fuzz`. `FUZZ_RUNS` sets
how many cases each property runs (default 1000). `mix test` skips them.
