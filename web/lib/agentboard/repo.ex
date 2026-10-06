defmodule Agentboard.Repo do
  use AshPostgres.Repo, otp_app: :agentboard

  def installed_extensions, do: ["ash-functions"]
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}

  @read_timeout 2_000
  @write_timeout 10_000

  defoverridable transaction: 1,
                 transaction: 2,
                 all: 1,
                 all: 2,
                 one: 1,
                 one: 2,
                 update_all: 2,
                 update_all: 3,
                 delete_all: 1,
                 delete_all: 2,
                 insert_all: 2,
                 insert_all: 3,
                 insert: 1,
                 insert: 2,
                 insert!: 1,
                 insert!: 2,
                 update: 1,
                 update: 2,
                 delete: 1,
                 delete: 2

  def transaction(fun_or_multi), do: transaction(fun_or_multi, [])

  def transaction(fun_or_multi, opts),
    do: super(fun_or_multi, Keyword.put(opts, :queue, false))

  def all(queryable), do: all(queryable, [])
  def all(queryable, opts), do: super(queryable, Keyword.put(opts, :queue, false))
  def one(queryable), do: one(queryable, [])
  def one(queryable, opts), do: super(queryable, Keyword.put(opts, :queue, false))

  def update_all(queryable, updates), do: update_all(queryable, updates, [])

  def update_all(queryable, updates, opts),
    do: super(queryable, updates, Keyword.put(opts, :queue, false))

  def delete_all(queryable), do: delete_all(queryable, [])
  def delete_all(queryable, opts), do: super(queryable, Keyword.put(opts, :queue, false))

  def insert_all(schema_or_source, entries), do: insert_all(schema_or_source, entries, [])

  def insert_all(schema_or_source, entries, opts),
    do: super(schema_or_source, entries, Keyword.put(opts, :queue, false))

  def insert(struct_or_changeset), do: insert(struct_or_changeset, [])

  def insert(struct_or_changeset, opts),
    do: super(struct_or_changeset, Keyword.put(opts, :queue, false))

  def insert!(struct_or_changeset), do: insert!(struct_or_changeset, [])

  def insert!(struct_or_changeset, opts),
    do: super(struct_or_changeset, Keyword.put(opts, :queue, false))

  def update(struct_or_changeset), do: update(struct_or_changeset, [])

  def update(struct_or_changeset, opts),
    do: super(struct_or_changeset, Keyword.put(opts, :queue, false))

  def delete(struct_or_changeset), do: delete(struct_or_changeset, [])

  def delete(struct_or_changeset, opts),
    do: super(struct_or_changeset, Keyword.put(opts, :queue, false))

  def read_query(query) do
    Ash.Query.set_context(query, %{data_layer: %{timeout: @read_timeout}})
  end

  def statement(sql, params, opts \\ []) do
    Ecto.Adapters.SQL.query(__MODULE__, sql, params, sql_opts(opts))
  end

  def statement!(sql, params, opts \\ []) do
    Ecto.Adapters.SQL.query!(__MODULE__, sql, params, sql_opts(opts))
  end

  def write_timeout, do: @write_timeout

  defp sql_opts(opts) do
    opts |> Keyword.put(:queue, false) |> Keyword.put_new(:timeout, @write_timeout)
  end
end
