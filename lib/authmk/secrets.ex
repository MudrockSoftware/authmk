defmodule Authmk.Secrets do
  @moduledoc """
  The secret authmk signs and encrypts with.

  Set `AUTHMK_SECRET` to a random value of at least 32 characters
  (`mix authmk.gen.secret` makes one), or pass `secret:` in config.

  To rotate, use versioned secrets, newest first, in `AUTHMK_SECRETS`
  (`"2:new-secret,1:old-secret"`) or `secrets: [{2, "new"}, {1, "old"}]`.
  New data uses the first one; data made with older ones stays readable
  until you remove them.
  """

  require Logger

  @min_length 32
  # Bits, estimated from the character set size and length.
  @min_entropy 120

  @type t :: [{non_neg_integer(), String.t()}]

  @doc """
  Resolves the secrets. Config comes before the environment, and versioned
  secrets before a single one: `secrets:`, `secret:`, `AUTHMK_SECRETS`,
  `AUTHMK_SECRET`. Raises when none is set or one is too short.
  """
  @spec resolve!(keyword()) :: t()
  def resolve!(opts) do
    secrets =
      cond do
        opts[:secrets] -> opts[:secrets]
        opts[:secret] -> [{0, opts[:secret]}]
        env = System.get_env("AUTHMK_SECRETS") -> parse!(env)
        env = System.get_env("AUTHMK_SECRET") -> [{0, env}]
        true -> raise ArgumentError, missing_message()
      end

    validate!(secrets)
  end

  @doc ~s(Parses `"2:new,1:old"` into `[{2, "new"}, {1, "old"}]`.)
  @spec parse!(String.t()) :: t()
  def parse!(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn entry ->
      with [version, secret] <- String.split(String.trim(entry), ":", parts: 2),
           {version, ""} when version >= 0 <- Integer.parse(version) do
        {version, secret}
      else
        _ -> raise ArgumentError, ~s(invalid AUTHMK_SECRETS entry. Expected "<version>:<secret>")
      end
    end)
  end

  defp validate!([]), do: raise(ArgumentError, "secrets must contain at least one entry")

  defp validate!(secrets) do
    versions = Enum.map(secrets, &elem(&1, 0))

    if Enum.uniq(versions) != versions do
      raise ArgumentError, "secret versions must be unique"
    end

    for {version, secret} <- secrets do
      if not is_binary(secret) or byte_size(secret) < @min_length do
        raise ArgumentError,
              "secret version #{version} must be at least #{@min_length} characters. " <>
                "Generate one with `mix authmk.gen.secret`"
      end
    end

    {_version, current} = hd(secrets)

    if entropy(current) < @min_entropy do
      Logger.warning(
        "Your authmk secret looks low-entropy. Use a random one: `mix authmk.gen.secret`"
      )
    end

    secrets
  end

  defp entropy(secret) do
    unique = secret |> String.graphemes() |> Enum.uniq() |> length()
    if unique < 2, do: 0, else: :math.log2(unique) * String.length(secret)
  end

  defp missing_message do
    "authmk needs a secret. Set the AUTHMK_SECRET environment variable to a random value " <>
      "of at least 32 characters (`mix authmk.gen.secret` makes one), or pass `secret:` in config"
  end
end
