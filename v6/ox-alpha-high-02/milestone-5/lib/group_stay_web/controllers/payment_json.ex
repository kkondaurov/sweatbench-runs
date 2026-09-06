defmodule GroupStayWeb.PaymentJSON do
  @moduledoc """
  Renders the current disposition of one recorded cash payment.
  """

  def data(statement) do
    base = %{
      "payment_operation_id" => statement.payment_operation_id,
      "original_group_id" => statement.original_group_id,
      "recorded_cents" => statement.recorded_cents,
      "held_cents" => statement.held_cents,
      "refunded_cents" => statement.refunded_cents,
      "retained_cents" => statement.retained_cents,
      "converted_to_credit_cents" => statement.converted_to_credit_cents,
      "reduced_cents" => statement.reduced_cents,
      "charged_back_cents" => statement.charged_back_cents
    }

    case Map.fetch(statement, :held_by_group) do
      {:ok, held_by_group} ->
        Map.put(base, "held_by_group",
          Enum.map(held_by_group, fn entry ->
            %{"group_id" => entry.group_id, "amount_cents" => entry.amount_cents}
          end)
        )

      :error ->
        # Payments that never participated in a transfer keep the earlier
        # statement shape.
        base
    end
  end
end
