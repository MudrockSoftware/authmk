defmodule Authmk.Plugins.SSO.SAML.RedirectBinding do
  @moduledoc false
  # SAML's HTTP-Redirect binding: a message deflated and base64'd into the
  # query string (`SAMLRequest` or `SAMLResponse`), with `RelayState`, and
  # signed over the query itself (`SigAlg`, `Signature`).
  #
  # Messages coming in are inflated up to @max_xml bytes (a deflate bomb
  # stops there), and their signature is checked over the query string as
  # it arrived, with one of the identity provider's certificates.

  alias Authmk.Plugins.SSO.SAML.Certificates

  @max_xml 64_000

  @signatures %{
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256" => {:rsa, :sha256},
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha384" => {:rsa, :sha384},
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512" => {:rsa, :sha512},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256" => {:ecdsa, :sha256},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha384" => {:ecdsa, :sha384},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha512" => {:ecdsa, :sha512}
  }

  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"

  @doc """
  `url` with the message: `param` is `"SAMLRequest"` or `"SAMLResponse"`.
  Signed with `key` (RSA, SHA-256) unless it's nil.
  """
  def url(url, param, xml, relay_state, key) do
    params =
      [{param, deflate(xml)}] ++
        if(relay_state, do: [{"RelayState", relay_state}], else: [])

    query = params |> sign(key) |> Enum.map_join("&", &pair/1)
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> query
  end

  defp sign(params, nil), do: params

  defp sign(params, key) do
    params = params ++ [{"SigAlg", @rsa_sha256}]
    signed = Enum.map_join(params, "&", &pair/1)
    params ++ [{"Signature", Base.encode64(Certificates.sign(signed, key))}]
  end

  defp pair({name, value}), do: name <> "=" <> URI.encode_www_form(value)

  @doc """
  The message in a signed redirect `query_string` (as it arrived), as
  `{:ok, xml, relay_state}`, or `{:error, reason}`. The signature must be
  there, and check out with one of `certificates`.
  """
  def verify(query_string, param, certificates) do
    raw = raw_pairs(query_string)
    params = Map.new(raw, fn {name, value} -> {name, URI.decode_www_form(value)} end)

    with {:ok, {key_type, hash}} <- Map.fetch(@signatures, params["SigAlg"]) |> found(),
         {:ok, signature} <- decode64(params["Signature"]),
         signed = signed_part(raw, param),
         true <-
           Enum.any?(certificates, &Certificates.verify(signed, hash, {key_type, signature}, &1)) ||
             {:error, :invalid_signature},
         {:ok, deflated} <- decode64(params[param]),
         {:ok, xml} <- inflate(deflated) do
      {:ok, xml, params["RelayState"]}
    end
  rescue
    ArgumentError -> {:error, :invalid_encoding}
  end

  defp found({:ok, value}), do: {:ok, value}
  defp found(:error), do: {:error, :unsigned}

  # The signed string: the parameters in this order, encoded as they came.
  defp signed_part(raw, param) do
    [param, "RelayState", "SigAlg"]
    |> Enum.flat_map(fn name ->
      case List.keyfind(raw, name, 0) do
        {^name, value} -> [name <> "=" <> value]
        nil -> []
      end
    end)
    |> Enum.join("&")
  end

  defp raw_pairs(query_string) do
    for pair <- String.split(query_string || "", "&", trim: true),
        [name, value] <- [String.split(pair, "=", parts: 2)],
        do: {name, value}
  end

  defp decode64(nil), do: {:error, :invalid_encoding}

  defp decode64(value) do
    case value |> String.replace(~r/\s+/, "") |> Base.decode64() do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_encoding}
    end
  end

  defp deflate(xml) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    compressed = :zlib.deflate(z, xml, :finish)
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)
    compressed |> IO.iodata_to_binary() |> Base.encode64()
  end

  # Raw deflate, read in chunks, and given up past @max_xml bytes.
  defp inflate(deflated) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, -15)

    try do
      z |> :zlib.safeInflate(deflated) |> collect(z, [], 0)
    catch
      :error, _data_error -> {:error, :invalid_encoding}
    after
      :zlib.close(z)
    end
  end

  defp collect({status, output}, z, acc, size) do
    size = size + IO.iodata_length(output)

    cond do
      size > @max_xml -> {:error, :too_large}
      status == :continue -> z |> :zlib.safeInflate([]) |> collect(z, [acc, output], size)
      status == :finished -> {:ok, IO.iodata_to_binary([acc, output])}
    end
  end
end
