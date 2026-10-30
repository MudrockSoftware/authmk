defmodule Authmk.Plugins.SCIM.Patch do
  @moduledoc false
  # PATCH (RFC 7644 3.5.2) on users and groups, as identity providers send
  # it: ops in any case ("Replace"), booleans as strings ("False", from
  # Entra ID), values with or without a path, dotted keys in value maps.

  @doc "SCIM booleans, including Entra ID's strings."
  def boolean(value) when is_boolean(value), do: value
  def boolean(value) when is_binary(value), do: String.downcase(value) == "true"
  def boolean(_value), do: false

  @doc "Applies PATCH operations to a user's attrs."
  def apply_user(attrs, params), do: apply_operations(attrs, params, &user_op/4)

  @doc "Applies PATCH operations to a group's attrs (`members` is a list of ids)."
  def apply_group(attrs, params), do: apply_operations(attrs, params, &group_op/4)

  defp apply_operations(attrs, %{"Operations" => [_ | _] = operations}, apply_op) do
    Enum.reduce_while(operations, {:ok, attrs}, fn operation, {:ok, attrs} ->
      case operation(operation, attrs, apply_op) do
        {:ok, attrs} -> {:cont, {:ok, attrs}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_operations(_attrs, _params, _apply_op),
    do: {:scim_error, 400, "invalidSyntax", "Operations are required"}

  defp operation(%{"op" => op} = operation, attrs, apply_op) when is_binary(op) do
    op = String.downcase(op)
    path = operation["path"]
    value = operation["value"]

    cond do
      op not in ["add", "replace", "remove"] ->
        {:scim_error, 400, "invalidSyntax", "Unknown op #{op}"}

      is_binary(path) ->
        apply_op.(attrs, op, String.downcase(path), value)

      op != "remove" and is_map(value) ->
        apply_map(attrs, op, value, apply_op)

      true ->
        {:scim_error, 400, "noTarget", "A path or a value object is required"}
    end
  end

  defp operation(_operation, _attrs, _apply_op),
    do: {:scim_error, 400, "invalidSyntax", "Every operation needs an op"}

  # No path: every key of the value is a path ("name" can hold sub-keys).
  defp apply_map(attrs, op, value, apply_op) do
    value
    |> Enum.flat_map(fn
      {"name", %{} = name} -> Enum.map(name, fn {key, sub} -> {"name." <> key, sub} end)
      pair -> [pair]
    end)
    |> Enum.reduce_while({:ok, attrs}, fn {path, sub}, {:ok, attrs} ->
      case apply_op.(attrs, op, String.downcase(path), sub) do
        {:ok, attrs} -> {:cont, {:ok, attrs}}
        error -> {:halt, error}
      end
    end)
  end

  @user_paths %{
    "username" => :user_name,
    "displayname" => :name,
    "name.formatted" => :name,
    "externalid" => :external_id,
    "name.givenname" => :given_name,
    "name.familyname" => :family_name
  }

  defp user_op(attrs, "remove", path, _value)
       when path in ["externalid", "name.givenname", "name.familyname"],
       do: {:ok, Map.put(attrs, @user_paths[path], nil)}

  defp user_op(_attrs, "remove", path, _value),
    do: {:scim_error, 400, "mutability", "#{path} can't be removed"}

  defp user_op(attrs, _op, "active", value), do: {:ok, %{attrs | active: boolean(value)}}

  defp user_op(attrs, _op, "emails", [_ | _] = emails) do
    case Enum.find(emails, &(is_map(&1) and boolean(&1["primary"]))) || hd(emails) do
      %{"value" => email} when is_binary(email) -> {:ok, %{attrs | email: email}}
      _invalid -> {:scim_error, 400, "invalidValue", "emails need a value"}
    end
  end

  defp user_op(attrs, _op, "emails[" <> _ = path, value) when is_binary(value) do
    if String.ends_with?(path, "].value"),
      do: {:ok, %{attrs | email: value}},
      else: {:scim_error, 400, "invalidPath", "Unsupported path #{path}"}
  end

  defp user_op(attrs, _op, path, value)
       when is_map_key(@user_paths, path) and (is_binary(value) or is_nil(value)),
       do: {:ok, Map.put(attrs, @user_paths[path], value)}

  defp user_op(_attrs, _op, path, _value),
    do: {:scim_error, 400, "invalidPath", "Unsupported path #{path}"}

  defp group_op(attrs, "replace", "displayname", value) when is_binary(value),
    do: {:ok, %{attrs | display_name: value}}

  defp group_op(attrs, _op, "externalid", value) when is_binary(value) or is_nil(value),
    do: {:ok, %{attrs | external_id: value}}

  defp group_op(attrs, "add", "members", value),
    do:
      with(
        {:ok, ids} <- member_ids(value),
        do: {:ok, %{attrs | members: Enum.uniq(attrs.members ++ ids)}}
      )

  defp group_op(attrs, "replace", "members", value),
    do: with({:ok, ids} <- member_ids(value), do: {:ok, %{attrs | members: Enum.uniq(ids)}})

  defp group_op(attrs, "remove", "members", nil), do: {:ok, %{attrs | members: []}}

  defp group_op(attrs, "remove", "members", value),
    do: with({:ok, ids} <- member_ids(value), do: {:ok, %{attrs | members: attrs.members -- ids}})

  # Okta and Entra ID remove one member with a filter in the path.
  defp group_op(attrs, "remove", "members[value eq " <> rest, _value) do
    case Regex.run(~r/\A"([^"]+)"\]\z/, rest, capture: :all_but_first) do
      [id] -> {:ok, %{attrs | members: attrs.members -- [id]}}
      nil -> {:scim_error, 400, "invalidPath", "Unsupported members filter"}
    end
  end

  defp group_op(_attrs, _op, path, _value),
    do: {:scim_error, 400, "invalidPath", "Unsupported path #{path}"}

  @doc "Member ids from `[%{\"value\" => id}]`."
  def member_ids(members) when is_list(members) do
    ids = for %{"value" => id} <- members, is_binary(id), do: id

    if length(ids) == length(members),
      do: {:ok, ids},
      else: {:scim_error, 400, "invalidValue", "Members need a value"}
  end

  def member_ids(_members), do: {:scim_error, 400, "invalidValue", "members must be a list"}
end
