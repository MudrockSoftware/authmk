defmodule Authmk.Providers.DiscordTest do
  use Authmk.Test.ProviderCase, provider: :discord

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "80351110224678912",
        "username" => "nelly",
        "global_name" => "Nelly",
        "discriminator" => "0",
        "avatar" => "8342729096ea3675442027381ff50dfe",
        "email" => "nelly@example.com",
        "verified" => true
      },
      overrides
    )
  end

  defp sign_in_with(browser, profile) do
    sign_in(browser, routes: %{"/api/users/@me" => profile})
  end

  test "signs in with the verified email, display name and avatar", %{browser: browser} do
    %{url: url, user: user} = sign_in_with(browser, profile())

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)
    assert "#{uri.host}#{uri.path}" == "discord.com/api/oauth2/authorize"
    assert query["scope"] == "identify email"
    assert query["prompt"] == "none"
    refute Map.has_key?(query, "code_challenge")
    refute Map.has_key?(query, "permissions")

    assert user["email"] == "nelly@example.com"
    assert user["email_verified"] == true
    assert user["name"] == "Nelly"

    assert user["image"] ==
             "https://cdn.discordapp.com/avatars/80351110224678912/8342729096ea3675442027381ff50dfe.png"
  end

  test "an unverified email stays unverified", %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"verified" => false}))
    assert user["email_verified"] == false
  end

  test "falls back to the username", %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"global_name" => nil}))
    assert user["name"] == "nelly"
  end

  test "animated avatars are GIFs", %{browser: browser} do
    %{user: user} =
      sign_in_with(browser, profile(%{"avatar" => "a_1269e74af4df7417b13759eae50c83dc"}))

    assert user["image"] =~
             ~r{/avatars/80351110224678912/a_1269e74af4df7417b13759eae50c83dc\.gif$}
  end

  test "users without an avatar get the default one for their id", %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"avatar" => nil}))
    assert user["image"] == "https://cdn.discordapp.com/embed/avatars/5.png"
  end

  test "legacy users get the default avatar for their discriminator", %{browser: browser} do
    %{user: user} = sign_in_with(browser, profile(%{"avatar" => nil, "discriminator" => "1337"}))
    assert user["image"] == "https://cdn.discordapp.com/embed/avatars/2.png"
  end
end

defmodule Authmk.Providers.DiscordBotTest do
  use Authmk.EmulationCase, async: true

  import Authmk.Test.ProviderCase

  defmodule Auth do
    use Authmk,
      otp_app: :authmk,
      repo: Authmk.Test.Repo,
      base_url: "http://localhost:4000",
      background: :inline,
      rate_limit: [enabled: false],
      social_providers: [
        discord: [
          client_id: "client-id",
          client_secret: "client-secret",
          scopes: ["bot"],
          permissions: 2048,
          prompt: "consent"
        ]
      ],
      advanced: [http_options: [plug: {Req.Test, __MODULE__}]]
  end

  @moduletag auth: Auth

  test "the bot scope sends the permissions, and the prompt can be changed", %{browser: browser} do
    profile = %{
      "id" => "1",
      "username" => "bot-owner",
      "email" => "owner@example.com",
      "avatar" => nil
    }

    %{url: url} = sign_in_through(browser, Auth, :discord, routes: %{"/api/users/@me" => profile})

    query = URI.decode_query(URI.parse(url).query)
    assert query["scope"] == "identify email bot"
    assert query["permissions"] == "2048"
    assert query["prompt"] == "consent"
  end
end
