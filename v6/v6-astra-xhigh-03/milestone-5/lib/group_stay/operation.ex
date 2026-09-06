defmodule GroupStay.Operation do
  @moduledoc "Durable submissions and results, ordered by their first commit using `id`."
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end

  # Preserve the context's atom keys and Date values when replaying stored JSON.
  # Only known server-defined fields are converted; all other stored JSON is preserved.
  @result_fields ~w(operation_id status code group_id deposit_due_cents revision amount_cents
                    outstanding_deposit_cents new_arrival_on new_departure_on policy_version
                    refundable_until refunded_cents retained_cents credit_issued_cents
                    expected_revision actual_revision cancelled_room_ids payment_operation_id
                    charged_back_cents source_group_id destination_group_id
                    source_outstanding_deposit_cents destination_outstanding_deposit_cents
                    source_revision destination_revision)a
  @date_fields ~w(new_arrival_on new_departure_on refundable_until)a
  @result_keys Map.new(@result_fields, &{Atom.to_string(&1), &1})

  def replay_result(%__MODULE__{result: result}) do
    for {key, value} <- result, into: %{} do
      key = Map.get(@result_keys, key, key)
      value = if key in @date_fields and is_binary(value), do: replay_date(value), else: value
      {key, value}
    end
  end

  defp replay_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      # Derived cancellation deadlines can extend beyond four-digit ISO years.
      # Replay their original JSON unchanged, without imposing new validation.
      {:error, _} -> value
    end
  end
end
