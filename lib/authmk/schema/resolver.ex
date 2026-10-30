defmodule Authmk.Schema.Resolver do
  @moduledoc false

  # Merges core models, plugin schemas and user config into one
  # `Authmk.Schema.Definition`. Runs at compile time; every problem raises an
  # `ArgumentError` that points at the `use Authmk` line.

  alias Authmk.Schema.{Core, Definition, Field, Model, PrimaryKey}

  @model_spec NimbleOptions.new!(
                plural: [type: :string],
                primary_key: [type: PrimaryKey.option_type()],
                fields: [type: :keyword_list, default: []],
                indexes: [type: {:list, :keyword_list}, default: []],
                timestamps: [type: :boolean, default: true]
              )

  @user_model_config NimbleOptions.new!(
                       table: [type: :string],
                       primary_key: [type: PrimaryKey.option_type()],
                       module: [type: :atom],
                       fields: [type: :keyword_list, default: []],
                       additional_fields: [type: :keyword_list, default: []]
                     )

  @doc """
  Resolves the schema for `auth` from its compile-time options: `:plugins`,
  `:schema`, `:table_naming`, `:table_prefix` and `:primary_key`.
  """
  @spec resolve(module(), keyword()) :: Definition.t()
  def resolve(auth, opts) do
    specs = Enum.reduce(opts[:plugins], Core.models(), &merge_plugin/2)
    user_config = opts[:schema]

    for {key, _} <- user_config, not Map.has_key?(specs, key) do
      raise ArgumentError, "schema config for unknown model #{inspect(key)}"
    end

    models =
      Map.new(specs, fn {key, spec} ->
        config = validate!(Keyword.get(user_config, key, []), @user_model_config, key)
        {key, build_model(auth, key, spec, config, opts)}
      end)

    definition = %Definition{primary_key: opts[:primary_key], models: models}
    :ok = check_references!(definition)
    # Raises when models reference each other in a cycle.
    _sorted = Definition.sorted_models(definition)
    definition
  end

  defp merge_plugin({plugin, plugin_opts}, specs) do
    Code.ensure_compiled!(plugin)

    if function_exported?(plugin, :schema, 1) do
      plugin_opts
      |> plugin.schema()
      |> Enum.reduce(specs, fn {key, spec}, acc -> merge_model(acc, key, spec, plugin) end)
    else
      specs
    end
  end

  defp merge_model(specs, key, spec, plugin) do
    case Map.fetch(specs, key) do
      :error ->
        Map.put(specs, key, spec)

      {:ok, existing} ->
        fields =
          Enum.reduce(spec[:fields] || [], existing[:fields], &add_field(&1, &2, key, plugin))

        indexes = (existing[:indexes] || []) ++ (spec[:indexes] || [])
        Map.put(specs, key, Keyword.merge(existing, fields: fields, indexes: indexes))
    end
  end

  defp add_field({name, spec}, fields, model_key, plugin) do
    case Keyword.fetch(fields, name) do
      :error ->
        fields ++ [{name, spec}]

      {:ok, ^spec} ->
        fields

      {:ok, _other} ->
        raise ArgumentError,
              "#{inspect(plugin)} defines #{model_key}.#{name} differently from another plugin"
    end
  end

  defp build_model(auth, key, spec, config, opts) do
    spec = validate!(spec, @model_spec, key)
    fields = build_fields(key, spec[:fields], config)

    table =
      config[:table] ||
        opts[:table_prefix] <> table_name(key, spec[:plural], opts[:table_naming])

    model = %Model{
      key: key,
      table: table,
      module: config[:module] || Module.concat(auth, Macro.camelize(Atom.to_string(key))),
      owner: if(config[:module], do: :user, else: :library),
      primary_key: config[:primary_key] || spec[:primary_key] || opts[:primary_key],
      fields: fields,
      indexes: [],
      timestamps: spec[:timestamps]
    }

    %{model | indexes: Enum.map(spec[:indexes], &build_index(model, &1))}
  end

  defp build_fields(key, specs, config) do
    for {name, _} <- config[:fields], not Keyword.has_key?(specs, name) do
      raise ArgumentError, "schema config renames unknown field #{key}.#{name}"
    end

    for {name, override} <- config[:fields], Keyword.keys(override) -- [:source] != [] do
      raise ArgumentError, "schema config for #{key}.#{name} may only set :source"
    end

    for {name, _} <- config[:additional_fields], Keyword.has_key?(specs, name) do
      raise ArgumentError, "additional field #{key}.#{name} already exists"
    end

    core =
      for {name, spec} <- specs do
        Field.new(name, Keyword.merge(spec, Keyword.get(config[:fields], name, [])))
      end

    core ++ for {name, spec} <- config[:additional_fields], do: Field.new(name, spec)
  end

  defp build_index(model, spec) do
    columns =
      for name <- Keyword.fetch!(spec, :columns) do
        field = Model.field(model, name) || raise ArgumentError, "index on unknown field #{name}"
        Field.column(field)
      end

    Model.index(model.table, columns, Keyword.get(spec, :unique, false))
  end

  defp table_name(key, _plural, :singular), do: Atom.to_string(key)
  defp table_name(key, nil, :plural), do: "#{key}s"
  defp table_name(_key, plural, :plural), do: plural

  defp check_references!(definition) do
    for {key, model} <- definition.models,
        field <- model.fields,
        field.references,
        not Map.has_key?(definition.models, field.references) do
      raise ArgumentError,
            "#{key}.#{field.name} references unknown model #{inspect(field.references)}"
    end

    :ok
  end

  defp validate!(opts, schema, key) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, opts} -> opts
      {:error, error} -> raise ArgumentError, "invalid model #{inspect(key)}: #{error.message}"
    end
  end
end
