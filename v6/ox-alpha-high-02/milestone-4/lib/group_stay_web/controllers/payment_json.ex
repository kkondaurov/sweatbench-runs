defmodule GroupStayWeb.PaymentJSON do
  @moduledoc """
  Renders the current disposition of one recorded cash payment.
  """

  def data(statement) do
    %{
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
  end
end
