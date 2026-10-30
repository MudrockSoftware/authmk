defmodule Authmk.Plugins.Security.ProofOfWork do
  @moduledoc false
  # Proof-of-work: before a protected request, the client finds a nonce
  # such that SHA-256(challenge <> nonce) starts with `difficulty` zero
  # bits. Cheap once, expensive at scale. Challenges are signed, expire
  # after 5 minutes, and work once.

  alias Authmk.{Crypto, Token}
  alias Authmk.Plugins.Security.Counters

  @purpose "security-pow"
  @ttl 300

  @doc "A new challenge at `difficulty` bits."
  def challenge(%{config: config}, difficulty) do
    data = %{
      "id" => Token.generate(12),
      "bits" => difficulty,
      "exp" => System.system_time(:second) + @ttl
    }

    %{challenge: Crypto.sign(config, @purpose, JSON.encode!(data)), difficulty: difficulty}
  end

  @doc "Checks the request's `x-pow-challenge` and `x-pow-nonce`: `:ok` or `:error`."
  def verify(%{conn: conn, config: config} = ctx) do
    with [challenge] <- Plug.Conn.get_req_header(conn, "x-pow-challenge"),
         [nonce] <- Plug.Conn.get_req_header(conn, "x-pow-nonce"),
         true <- byte_size(nonce) <= 64,
         {:ok, json} <- Crypto.verify(config, @purpose, challenge),
         {:ok, %{"id" => id, "bits" => bits, "exp" => exp}} <- JSON.decode(json),
         true <- exp > System.system_time(:second),
         true <- leading_zero_bits(:crypto.hash(:sha256, challenge <> nonce)) >= bits,
         nil <- Counters.get(ctx, "pow:" <> id) do
      :ok = Counters.put(ctx, "pow:" <> id, "used", @ttl)
    else
      _invalid -> :error
    end
  end

  @doc "Solves a challenge, for tests and Elixir clients."
  def solve(challenge, bits, nonce \\ 0) do
    if leading_zero_bits(:crypto.hash(:sha256, challenge <> Integer.to_string(nonce))) >= bits,
      do: Integer.to_string(nonce),
      else: solve(challenge, bits, nonce + 1)
  end

  defp leading_zero_bits(<<0::1, rest::bitstring>>), do: 1 + leading_zero_bits(rest)
  defp leading_zero_bits(_bits), do: 0
end
