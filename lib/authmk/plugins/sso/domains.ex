defmodule Authmk.Plugins.SSO.Domains do
  @moduledoc false
  # Proving a provider's domain with a DNS TXT record, before emails at that
  # domain go to it and existing users there may be linked to it.

  alias Authmk.{Context, Error, Token, Verification}
  alias Authmk.Plugins.SSO.{Config, Providers}

  @purpose "sso-domain"
  @expires_in 7 * 24 * 60 * 60

  @doc "The TXT record name for a domain."
  def record_name(domain), do: "_authmk-sso." <> domain

  @doc "A new challenge: the record to publish and its value."
  def request(ctx, provider) do
    value = "authmk-sso-verification=" <> Token.generate(24)

    with {:ok, _token} <-
           Verification.create(
             ctx,
             @purpose,
             %{"value" => value},
             @expires_in,
             provider.provider_id
           ) do
      {:ok, %{record: record_name(provider.domain), value: value}}
    end
  end

  @doc "Looks the record up; marks the domain verified when it's there."
  def verify(ctx, provider) do
    with {:ok, %{"value" => value}} <- Verification.peek(ctx, @purpose, provider.provider_id),
         {:ok, values} <- lookup(ctx, record_name(provider.domain)),
         true <- Enum.any?(values, &Plug.Crypto.secure_compare(&1, value)),
         :ok <- Providers.mark_verified(ctx, provider) do
      :ok = Verification.delete(ctx, @purpose, provider.provider_id)
    else
      _missing ->
        {:error,
         Error.custom(
           :domain_not_verified,
           400,
           "The TXT record wasn't found; DNS may take a while"
         )}
    end
  end

  defp lookup(%Context{} = ctx, name) do
    case Config.opts(ctx)[:resolve_txt] do
      nil -> dns_txt(name)
      resolve -> resolve.(name)
    end
  end

  defp dns_txt(name) do
    values =
      name
      |> String.to_charlist()
      |> :inet_res.lookup(:in, :txt)
      |> Enum.map(&IO.iodata_to_binary/1)

    {:ok, values}
  end
end
