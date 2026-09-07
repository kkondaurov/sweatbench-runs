defmodule GroupStay.Operations do
  @moduledoc """
  Durable idempotency and audit history for partner operations.

  An immediate transaction locks out competing writers before looking up the
  identifier. The domain change and its result then commit together. A savepoint
  discards domain changes on handled rejections while letting the rejection be
  remembered. Exceptions propagate and roll back the entire operation transaction.

  Payloads are decoded JSON maps: map equality ignores object key order, while
  strict equality preserves array order and value types. Only nonempty string
  identifiers can be remembered; unidentified submissions remain invalid operations.
  """
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  # Declare result keys here so cold retries do not depend on domain modules
  # having been loaded. Nested values (notably expected_revision) remain JSON.
  @result_keys ~w(operation_id status code group_id revision deposit_due_cents
                  amount_cents outstanding_deposit_cents new_arrival_on new_departure_on
                  policy_version refundable_until refunded_cents retained_cents
                  credit_issued_cents expected_revision actual_revision cancelled_room_ids
                  payment_operation_id charged_back_cents source_group_id destination_group_id
                  source_outstanding_deposit_cents destination_outstanding_deposit_cents
                  source_revision destination_revision starts_on period_end_on)a
  @result_fields Map.new(@result_keys, &{Atom.to_string(&1), &1})

  def get_result(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> nil
      operation -> operation.result
    end
  end

  @doc """
  Runs a domain callback for a new identifier, or returns the original result.

  The callback returns `{:ok, fields}` or `{:error, code_or_fields}` and must make
  all mutations through this repository. Results have atom keys at the top level
  and JSON values, including ISO date strings, on both first attempts and retries.
  """
  def execute(%{"operation_id" => id} = payload, apply_operation)
      when is_binary(id) and id != "" do
    {:ok, result} =
      Repo.with_write_transaction(fn ->
        result =
          case Repo.get_by(Operation, operation_id: id) do
            nil -> remember(payload, apply_operation)
            %Operation{payload: ^payload, result: result} -> result
            %Operation{} -> rejection(id, "operation_id_conflict")
          end

        Map.new(result, fn {key, value} -> {Map.fetch!(@result_fields, key), value} end)
      end)

    result
  end

  def execute(payload, _apply_operation) do
    id = if is_map(payload), do: payload["operation_id"]
    %{operation_id: id, status: "rejected", code: "invalid_operation"}
  end

  defp remember(payload, apply_operation) do
    Repo.query!("SAVEPOINT operation_domain")

    result =
      case apply_operation.() do
        {:ok, fields} ->
          Map.put(fields, :status, "applied")

        {:error, error} ->
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          fields = if is_binary(error), do: %{code: error}, else: error
          Map.put(fields, :status, "rejected")
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")

    result =
      result
      |> Map.put(:operation_id, payload["operation_id"])
      |> Jason.encode!()
      |> Jason.decode!()

    Repo.insert!(%Operation{
      operation_id: payload["operation_id"],
      type: if(is_binary(payload["type"]), do: payload["type"]),
      payload: payload,
      result: result
    })

    result
  end

  defp rejection(id, code) do
    %{"operation_id" => id, "status" => "rejected", "code" => code}
  end
end
