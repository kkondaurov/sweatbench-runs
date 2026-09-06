defmodule GroupStayWeb.PaymentJSON do
  @doc """
  Where the cash of one payment currently sits. The six dispositions add up to the cash the
  payment recorded, whatever has happened to the group since.

  A payment whose cash has taken part in a transfer also says which groups hold it now; one that
  never has keeps the statement it always had.
  """
  def show(%{statement: statement}) do
    data = %{
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

    case statement do
      %{held_by_group: held_by_group} -> %{data: Map.put(data, :held_by_group, held_by_group)}
      _statement -> %{data: data}
    end
  end

  def error(%{code: code}), do: %{error: %{code: code}}
end
