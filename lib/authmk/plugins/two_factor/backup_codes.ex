defmodule Authmk.Plugins.TwoFactor.BackupCodes do
  @moduledoc false
  # Single-use recovery codes, stored encrypted so users can view them again.

  import Ecto.Query, only: [from: 2]

  alias Authmk.{Crypto, Store}

  @purpose "two-factor-backup-codes"
  # 32 characters without look-alikes (0/O, 1/I): a random byte maps to one
  # without bias.
  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  def generate(opts) do
    for _ <- 1..opts[:backup_code_count], do: code(opts[:backup_code_length])
  end

  def encrypt(config, codes), do: Crypto.encrypt(config, @purpose, JSON.encode!(codes))

  def decrypt(config, encrypted) do
    {:ok, json} = Crypto.decrypt(config, @purpose, encrypted)
    JSON.decode!(json)
  end

  @doc """
  Uses up `code` when it is one of the user's. The update only applies to
  the codes as read, so a code works once even under concurrent requests.
  """
  def use(ctx, two_factor, code) do
    codes = decrypt(ctx.config, two_factor.backup_codes)
    given = normalize(code)

    case Enum.find(codes, &Plug.Crypto.secure_compare(normalize(&1), given)) do
      nil -> false
      used -> replace(ctx, two_factor, List.delete(codes, used))
    end
  end

  defp replace(ctx, two_factor, codes) do
    %{id: id, backup_codes: old} = two_factor

    query =
      from(t in Store.module(ctx, :two_factor), where: t.id == ^id and t.backup_codes == ^old)

    Store.update_all(ctx, :two_factor, query, set: [backup_codes: encrypt(ctx.config, codes)]) ==
      1
  end

  defp code(length) do
    chars =
      for <<byte <- :crypto.strong_rand_bytes(length)>>, do: Enum.at(@alphabet, rem(byte, 32))

    {first, second} = Enum.split(chars, div(length, 2))
    "#{first}-#{second}"
  end

  defp normalize(code), do: code |> String.upcase() |> String.replace(["-", " "], "")
end
