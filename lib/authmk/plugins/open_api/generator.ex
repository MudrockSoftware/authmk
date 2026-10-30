defmodule Authmk.Plugins.OpenAPI.Generator do
  @moduledoc false
  # Builds the OpenAPI 3.1 document from the config's endpoints and schema.

  alias Authmk.{Context, Cookies, Endpoint}
  alias Authmk.Schema.Model

  @openapi_version "3.1.1"

  def spec(%Context{config: config} = ctx) do
    %{
      openapi: @openapi_version,
      info: %{
        title: "#{config.app_name} API",
        version: to_string(Application.spec(:authmk, :vsn))
      },
      servers: servers(ctx),
      paths: paths(config.endpoints),
      components: %{
        securitySchemes: security_schemes(ctx),
        schemas: Map.put(model_schemas(config.schema), "Error", error_schema())
      }
    }
  end

  defp servers(%Context{base_url: nil}), do: []

  defp servers(%Context{base_url: base_url, config: config}),
    do: [%{url: base_url <> config.base_path}]

  defp paths(endpoints) do
    endpoints
    |> Enum.group_by(&openapi_path(&1.path))
    |> Map.new(fn {path, endpoints} ->
      {path, Map.new(endpoints, &{Atom.to_string(&1.method), operation(&1)})}
    end)
  end

  # `/callback/:provider` -> `/callback/{provider}`
  defp openapi_path(path),
    do: String.replace(path, ~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, "{\\1}")

  defp path_params(path) do
    ~r/:([a-zA-Z_][a-zA-Z0-9_]*)/
    |> Regex.scan(path, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
  end

  defp operation(%Endpoint{} = endpoint) do
    in_path = path_params(endpoint.path)

    {path_specs, other_specs} =
      Enum.split_with(endpoint.params, fn {name, _opts} -> Atom.to_string(name) in in_path end)

    %{
      operationId: Atom.to_string(endpoint.name),
      summary:
        endpoint.name |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize(),
      tags: [tag(endpoint)],
      parameters: parameters(endpoint, in_path, path_specs, other_specs),
      responses: %{
        "200" => %{
          description: "Success",
          content: %{"application/json" => %{schema: %{type: "object"}}}
        },
        "default" => %{
          description: "Error",
          content: %{"application/json" => %{schema: %{"$ref" => "#/components/schemas/Error"}}}
        }
      }
    }
    |> put_request_body(endpoint, other_specs)
    |> put_security(endpoint)
  end

  defp tag(%Endpoint{plugin: nil}), do: "Core"
  defp tag(%Endpoint{plugin: plugin}), do: plugin |> Module.split() |> List.last()

  defp parameters(endpoint, in_path, path_specs, other_specs) do
    path = for name <- in_path, do: path_param(name, path_specs)

    query =
      if endpoint.method == :get,
        do: for({name, opts} <- other_specs, do: query_param(name, opts)),
        else: []

    path ++ query
  end

  defp path_param(name, specs) do
    opts =
      Enum.find_value(specs, [type: :string], fn {param, opts} ->
        if Atom.to_string(param) == name, do: opts
      end)

    %{name: name, in: "path", required: true, schema: type_schema(opts[:type])}
  end

  defp query_param(name, opts) do
    %{
      name: Atom.to_string(name),
      in: "query",
      required: opts[:required] == true,
      schema: param_schema(opts)
    }
  end

  defp put_request_body(operation, %Endpoint{method: :post}, specs) when specs != [] do
    required = for {name, opts} <- specs, opts[:required], do: Atom.to_string(name)

    schema =
      %{
        type: "object",
        properties:
          Map.new(specs, fn {name, opts} -> {Atom.to_string(name), param_schema(opts)} end)
      }
      |> then(&if required == [], do: &1, else: Map.put(&1, :required, required))

    Map.put(operation, :requestBody, %{
      required: required != [],
      content: %{"application/json" => %{schema: schema}}
    })
  end

  defp put_request_body(operation, _endpoint, _specs), do: operation

  defp put_security(operation, %Endpoint{session: :required}),
    do: Map.put(operation, :security, [%{"session_cookie" => []}, %{"bearer" => []}])

  defp put_security(operation, _endpoint), do: operation

  defp param_schema(opts) do
    schema = type_schema(opts[:type])

    case Keyword.fetch(opts, :default) do
      {:ok, default} when not is_nil(default) -> Map.put(schema, :default, default)
      _no_default -> schema
    end
  end

  defp type_schema(:string), do: %{type: "string"}
  defp type_schema(:boolean), do: %{type: "boolean"}
  defp type_schema(type) when type in [:integer, :id], do: %{type: "integer"}
  defp type_schema(:float), do: %{type: "number"}
  defp type_schema(:map), do: %{type: "object"}
  defp type_schema({:map, _values}), do: %{type: "object"}
  defp type_schema({:array, items}), do: %{type: "array", items: type_schema(items)}

  defp type_schema(type) when type in [:utc_datetime, :utc_datetime_usec, :naive_datetime],
    do: %{type: "string", format: "date-time"}

  defp type_schema(_other), do: %{}

  defp security_schemes(ctx) do
    %{
      "session_cookie" => %{
        type: "apiKey",
        in: "cookie",
        name: Cookies.name(ctx, :session_token)
      },
      "bearer" => %{
        type: "http",
        scheme: "bearer",
        description: "The session token, with Authmk.Plugins.Bearer"
      }
    }
  end

  defp model_schemas(definition) do
    Map.new(definition.models, fn {key, %Model{} = model} ->
      {Macro.camelize(Atom.to_string(key)), model_schema(definition, model)}
    end)
  end

  defp model_schema(definition, model) do
    fields = for field <- model.fields, field.returned, do: field

    timestamps =
      if model.timestamps,
        do: [{"inserted_at", date_time()}, {"updated_at", date_time()}],
        else: []

    properties =
      [{"id", id_schema(definition.primary_key)}] ++
        Enum.map(fields, &{Atom.to_string(&1.name), field_schema(definition, &1)}) ++ timestamps

    required =
      ["id"] ++
        for(field <- fields, field.required, do: Atom.to_string(field.name)) ++
        Enum.map(timestamps, &elem(&1, 0))

    %{type: "object", properties: Map.new(properties), required: required}
  end

  defp field_schema(definition, field) do
    schema =
      cond do
        field.references -> id_schema(definition.primary_key)
        field.type == :datetime -> date_time()
        field.type == :text -> %{type: "string"}
        true -> type_schema(field.type)
      end

    if field.required, do: schema, else: nullable(schema)
  end

  defp nullable(%{type: type} = schema), do: %{schema | type: [type, "null"]}
  defp nullable(schema), do: schema

  defp id_schema(:id), do: %{type: "integer"}
  defp id_schema(_string_key), do: %{type: "string"}

  defp date_time, do: %{type: "string", format: "date-time"}

  defp error_schema do
    %{
      type: "object",
      required: ["error"],
      properties: %{
        "error" => %{
          type: "object",
          required: ["code", "message"],
          properties: %{
            "code" => %{type: "string"},
            "message" => %{type: "string"},
            "details" => %{type: "object"}
          }
        }
      }
    }
  end
end
