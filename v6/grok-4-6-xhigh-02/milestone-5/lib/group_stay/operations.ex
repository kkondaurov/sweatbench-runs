defmodule GroupStay.Operations do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  def get(operation_id) when is_binary(operation_id) do
    Repo.get_by(Operation, operation_id: operation_id)
  end

  def get(_), do: nil

  def get_result(operation_id) do
    case get(operation_id) do
      %Operation{result: result} when is_map(result) -> result
      _ -> nil
    end
  end

  def list_in_commit_order do
    from(o in Operation, order_by: [asc: o.id])
    |> Repo.all()
  end

  def claim(operation_id, type, payload) when is_binary(operation_id) do
    case get(operation_id) do
      %Operation{} = record ->
        {:existing, record}

      nil ->
        insert_claim(operation_id, type, payload)
    end
  end

  def put_result!(record, result) do
    record
    |> Operation.changeset(%{result: json_ready(result)})
    |> Repo.update!()
    |> Map.fetch!(:result)
  end

  def replay_or_conflict(%Operation{} = record, payload) do
    if record.payload == payload do
      record.result
    else
      %{
        operation_id: record.operation_id,
        status: "rejected",
        code: "operation_id_conflict"
      }
    end
  end

  def canonicalize(%Date{} = date), do: Date.to_iso8601(date)
  def canonicalize(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def canonicalize(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)

  def canonicalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {canonicalize_key(key), canonicalize(value)} end)
  end

  def canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  def canonicalize(other), do: other

  def json_ready(value), do: canonicalize(value)

  defp insert_claim(operation_id, type, payload) do
    %Operation{}
    |> Operation.changeset(%{
      operation_id: operation_id,
      type: type,
      payload: payload
    })
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        if unique_operation_id_error?(changeset) do
          {:existing, Repo.get_by!(Operation, operation_id: operation_id)}
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  rescue
    e in [Ecto.ConstraintError] ->
      if e.type == :unique do
        {:existing, Repo.get_by!(Operation, operation_id: operation_id)}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp canonicalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonicalize_key(key) when is_binary(key), do: key
  defp canonicalize_key(key), do: to_string(key)

  defp unique_operation_id_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:operation_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end
end
