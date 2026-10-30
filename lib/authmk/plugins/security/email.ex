defmodule Authmk.Plugins.Security.Email do
  @moduledoc false
  # Sign-up email checks: throwaway providers, domains that can't receive
  # mail, and one person's many spellings of one address.

  # Common disposable providers. Not exhaustive: `on_event` sees what passes.
  @disposable ~w(
    10minutemail.com 20minutemail.com 33mail.com dispostable.com dropmail.me emailondeck.com
    fakeinbox.com getairmail.com getnada.com guerrillamail.com guerrillamail.net guerrillamail.org
    guerrillamailblock.com maildrop.cc mailinator.com mailinator.net mailnesia.com mintemail.com
    mohmal.com mytemp.email nada.email sharklasers.com spamgourmet.com temp-mail.org temp-mail.io
    tempmail.com tempmail.net tempmailo.com tempr.email throwawaymail.com trashmail.com trashmail.de
    yopmail.com yopmail.fr yopmail.net moakt.com mail.tm inboxkitten.com burnermail.io
    discard.email emailfake.com fakemail.net spambox.us tmail.ws tmpmail.org tmpmail.net
  )

  # Providers where dots in the local part don't matter.
  @dotless ["gmail.com", "googlemail.com"]

  @doc "Whether the domain is a known throwaway provider (or a subdomain of one)."
  def disposable?(email) do
    domain = domain(email)
    Enum.any?(@disposable, &(domain == &1 or String.ends_with?(domain, "." <> &1)))
  end

  @doc """
  One spelling per mailbox: lowercase, without `+tags`, and without dots
  where the provider ignores them (`A.B+x@googlemail.com` -> `ab@gmail.com`).
  """
  def canonical(email) do
    case String.split(String.downcase(email), "@") do
      [local, domain] ->
        local = local |> String.split("+") |> hd()
        domain = if domain == "googlemail.com", do: "gmail.com", else: domain
        local = if domain in @dotless, do: String.replace(local, ".", ""), else: local
        local <> "@" <> domain

      _invalid ->
        String.downcase(email)
    end
  end

  @doc "Whether the domain can receive mail (MX records, or an address for it)."
  def receives_mail?(email, resolve_mx) do
    domain = domain(email)

    case (resolve_mx || (&dns_mx/1)).(domain) do
      {:ok, [_ | _]} -> true
      _none -> false
    end
  end

  defp dns_mx(domain) do
    host = String.to_charlist(domain)

    case :inet_res.lookup(host, :in, :mx) do
      [_ | _] = records -> {:ok, records}
      [] -> if :inet_res.lookup(host, :in, :a) == [], do: :error, else: {:ok, [domain]}
    end
  end

  defp domain(email), do: email |> String.downcase() |> String.split("@") |> List.last()
end
