defmodule GroupStay.Operations do
  @moduledoc """
  Durable partner submissions and their original JSON results.

  The immediate write transaction serializes lookup, domain effects, and audit
  insertion. Increasing record IDs describe first-commit order because SQLite
  permits only one writer at a time. Submissions without a usable identifier
  cannot be retried by identifier and are rejected without an audit record.
  """
  use Ecto.Schema
  alias GroupStay.Repo

  schema "partner_operations" do
    field :operation_id, :string
    field :type, :string
    field :submission, :map
    field :result, :map
  end

  @result_keys Map.new(
                 ~w(period_end_on starts_on operation_id status code group_id deposit_due_cents revision amount_cents
                    outstanding_deposit_cents expected_revision actual_revision new_arrival_on
                    new_departure_on policy_version refundable_until refunded_cents retained_cents
                    credit_issued_cents cancelled_room_ids payment_operation_id charged_back_cents
                    source_group_id destination_group_id source_outstanding_deposit_cents
                    destination_outstanding_deposit_cents source_revision destination_revision)a,
                 &{Atom.to_string(&1), &1}
               )

  defmodule Rejection do
    @moduledoc false
    defexception [:fields]
    def message(_), do: "partner operation rejected"
  end

  def reject(fields), do: raise(Rejection, fields: fields)

  def get_result(id) do
    case Repo.get_by(__MODULE__, operation_id: id) do
      nil -> nil
      record -> result_fields(record.result)
    end
  end

  def execute(submission, apply) do
    id = if is_map(submission), do: submission["operation_id"]

    {:ok, result} =
      Repo.write_transaction(fn ->
        if is_binary(id) and byte_size(id) > 0 do
          case Repo.get_by(__MODULE__, operation_id: id) do
            nil ->
              remember(submission, id, apply)

            %{submission: original, result: result} when original === submission ->
              result_fields(result)

            _ ->
              %{operation_id: id, status: "rejected", code: "operation_id_conflict"}
          end
        else
          %{operation_id: id, status: "rejected", code: "invalid_operation"}
        end
      end)

    result
  end

  defp remember(submission, id, apply) do
    # A handled rejection undoes even partial domain writes, while leaving the
    # outer transaction available to commit the rejection's audit record.
    Repo.query!("SAVEPOINT partner_domain")

    result =
      try do
        Map.merge(apply.(), %{operation_id: id, status: "applied"})
      rescue
        error in Rejection ->
          Repo.query!("ROLLBACK TO SAVEPOINT partner_domain")
          Map.merge(error.fields, %{operation_id: id, status: "rejected"})
      end

    Repo.query!("RELEASE SAVEPOINT partner_domain")
    json_result = result |> Jason.encode!() |> Jason.decode!()

    Repo.insert!(%__MODULE__{
      operation_id: id,
      type: if(is_binary(submission["type"]), do: submission["type"]),
      submission: submission,
      result: json_result
    })

    result_fields(json_result)
  end

  # Only server-defined top-level field names become atoms. Partner content in
  # values (including malformed expected revisions) remains untouched.
  defp result_fields(result),
    do:
      Map.new(result, fn {key, value} ->
        {Map.fetch!(@result_keys, key), result_value(key, value)}
      end)

  defp result_value(key, value)
       when key in ["new_arrival_on", "new_departure_on", "refundable_until"] and is_binary(value),
       do: Date.from_iso8601!(value)

  defp result_value(_, value), do: value
end
