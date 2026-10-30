defmodule Authmk.License do
  @moduledoc """
  The licence key for authmk's licensed features: the admin dashboard and
  its analytics (everything under `licensed/`, which isn't MIT licensed).

  Set it in the environment:

      AUTHMK_LICENCE_KEY=authmk_live_...

  In development and tests (running under Mix in `:dev` or `:test`) no key
  is needed. Everywhere else, including releases, the licensed features
  refuse to run without a valid one.

  Keys will be checked against the licence server at
  `https://license.mudrock.dev`. Until it runs, a key is valid when it has
  the right shape: `authmk_` followed by at least 24 letters, digits,
  `_` or `-`.
  """

  @env_var "AUTHMK_LICENCE_KEY"
  @key_format ~r/\Aauthmk_[A-Za-z0-9_-]{24,}\z/

  @doc "The environment variable that holds the key."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  Whether licensed features may run: `:ok`, or `{:error, :missing}` /
  `{:error, :invalid}`.

  Options, for tests: `:env` (default: Mix's, or `:prod` without Mix) and
  `:key` (default: the environment variable).
  """
  @spec check(keyword()) :: :ok | {:error, :missing | :invalid}
  def check(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &current_env/0)
    key = Keyword.get_lazy(opts, :key, fn -> System.get_env(@env_var) end)

    cond do
      env in [:dev, :test] -> :ok
      key in [nil, ""] -> {:error, :missing}
      true -> verify(String.trim(key))
    end
  end

  @doc "Why `check/1` failed, in words for logs and pages."
  @spec explain(:missing | :invalid) :: String.t()
  def explain(:missing), do: "No licence key: set #{@env_var} to use authmk's dashboard."
  def explain(:invalid), do: "The licence key in #{@env_var} isn't valid."

  # A stand-in for the licence server: the key's shape only.
  defp verify(key) do
    if Regex.match?(@key_format, key), do: :ok, else: {:error, :invalid}
  end

  # Releases run without Mix: that's production.
  defp current_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0),
      do: Mix.env(),
      else: :prod
  end
end
