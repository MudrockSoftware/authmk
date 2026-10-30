defmodule Authmk.Pages do
  @moduledoc false
  # The pages authmk shows people itself, like the sign-in error page: a
  # small SvelteKit app (assets/pages), built into priv/pages. A page is its
  # shell with the page's data in a JSON block the browser never runs; the
  # shell's Content-Security-Policy allows only its own script.

  @dir "priv/pages"

  @doc "Where the built pages live."
  def dir, do: Application.app_dir(:authmk, @dir)

  @doc "The page `name` with `data`, or `:missing` when the build isn't there."
  @spec render(String.t(), map()) :: {:ok, String.t()} | :missing
  def render(name, data) do
    case File.read(Path.join(dir(), "index.html")) do
      {:ok, shell} ->
        block =
          ~s(<script type="application/json" id="authmk-page">) <>
            json(Map.put(data, :name, name)) <> "</script>"

        {:ok, String.replace(shell, "</head>", block <> "</head>", global: false)}

      {:error, _missing} ->
        :missing
    end
  end

  # Text from the request (an error description) ends up here: nothing in
  # it may close the block or start markup.
  defp json(data) do
    data
    |> JSON.encode!()
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace("&", "\\u0026")
    |> String.replace("\u2028", "\\u2028")
    |> String.replace("\u2029", "\\u2029")
  end
end
