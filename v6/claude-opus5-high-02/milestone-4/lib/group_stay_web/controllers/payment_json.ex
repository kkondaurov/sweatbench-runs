defmodule GroupStayWeb.PaymentJSON do
  @doc """
  Where the cash of one payment currently sits. The six dispositions add up to the cash the
  payment recorded, whatever has happened to the group since.
  """
  def show(%{statement: statement}) do
    %{
      data: %{
        payment_operation_id: statement.payment_operation_id,
        original_group_id: statement.original_group_id,
        recorded_cents: statement.recorded_cents,
        held_cents: statement.held_cents,
        refunded_cents: statement.refunded_cents,
        retained_cents: statement.retained_cents,
        converted_to_credit_cents: statement.converted_to_credit_cents,
        reduced_cents: statement.reduced_cents,
        charged_back_cents: statement.charged_back_cents
      }
    }
  end

  def error(%{code: code}), do: %{error: %{code: code}}
end
