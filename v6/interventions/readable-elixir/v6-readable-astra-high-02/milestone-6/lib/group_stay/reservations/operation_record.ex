defmodule GroupStay.Reservations.OperationRecord do
  @moduledoc """
  The durable, append-only audit of partner submissions and their original results.

  SQLite's immediate write transaction serializes first submissions across connections
  and service processes. Its generated integer ID therefore records first-commit order,
  including rejections. The payload, result, and domain effects commit together.

  Payloads are compared as decoded JSON using strict equality: object key order is
  irrelevant, while array order and value types remain significant. Unknown fields
  are retained and compared too. Malformed envelopes with a usable operation ID are
  remembered; a missing or non-string type is retained in the payload itself.
  """
  use Ecto.Schema

  alias GroupStay.Repo
  alias GroupStay.Reservations.Operation

  # Declare the result vocabulary here so reads also work immediately after a cold
  # start, before any domain module that produces these keys has been loaded.
  @result_keys Map.new(
                 ~w(operation_id status code group_id revision deposit_due_cents
                    amount_cents outstanding_deposit_cents new_arrival_on new_departure_on
                    policy_version refundable_until refunded_cents retained_cents
                    credit_issued_cents expected_revision actual_revision cancelled_room_ids
                    payment_operation_id charged_back_cents source_group_id destination_group_id
                    source_outstanding_deposit_cents destination_outstanding_deposit_cents
                    source_revision destination_revision starts_on)a,
                 &{Atom.to_string(&1), &1}
               )

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end

  def get_result(operation_id) do
    case Repo.get_by(__MODULE__, operation_id: operation_id) do
      nil -> {:error, "operation_not_found"}
      record -> {:ok, result(record)}
    end
  end

  @doc "Runs a first submission once, or returns its original result without domain reads."
  def run(operation, execute) do
    operation_id = if is_map(operation), do: operation["operation_id"]

    if Operation.identifier?(operation_id) do
      {:ok, result} =
        Repo.with_write_lock(fn ->
          case Repo.get_by(__MODULE__, operation_id: operation_id) do
            nil -> remember(operation, execute.())
            %{payload: payload} = record when payload === operation -> result(record)
            _ -> %{operation_id: operation_id, status: "rejected", code: "operation_id_conflict"}
          end
        end)

      result
    else
      # Without a usable identifier validation rejects before any domain mutation.
      execute.()
    end
  end

  defp remember(operation, result) do
    Repo.insert!(%__MODULE__{
      operation_id: operation["operation_id"],
      type: if(is_binary(operation["type"]), do: operation["type"]),
      payload: operation,
      result: result
    })

    result
  end

  defp result(record) do
    # Only the service-defined result keys become atoms. Partner data nested inside
    # stale-revision details stays untouched, and no atoms are created from input.
    Map.new(record.result, fn {key, value} -> {Map.fetch!(@result_keys, key), value} end)
  end
end
