defmodule GroupStay.Operations.Record do
  @moduledoc """
  An immutable submission and its original outcome, including handled rejections.

  SQLite serializes writers, so the generated `id` orders first commits. Retries
  and conflicts never insert or update a record. Missing or non-string types are
  stored as null in `type`; the complete malformed value remains in `payload`.
  """
  use Ecto.Schema

  schema "operations" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end

  @result_keys Map.new(
                 ~w(operation_id status code group_id expected_revision actual_revision
                    deposit_due_cents revision amount_cents outstanding_deposit_cents
                    new_arrival_on new_departure_on policy_version refundable_until
                    refunded_cents retained_cents credit_issued_cents cancelled_room_ids
                    payment_operation_id charged_back_cents)a,
                 &{Atom.to_string(&1), &1}
               )

  @doc "Restores the context's atom keys and calendar dates from the stored JSON result."
  def original_result(%__MODULE__{result: result}) do
    Map.new(result, fn {key, value} ->
      # Only our generated, top-level result keys become atoms. Partner content
      # (including arbitrary expected_revision values) remains untouched.
      value =
        if key in ~w(new_arrival_on new_departure_on refundable_until) and is_binary(value),
          do: Date.from_iso8601!(value),
          else: value

      {Map.fetch!(@result_keys, key), value}
    end)
  end
end
