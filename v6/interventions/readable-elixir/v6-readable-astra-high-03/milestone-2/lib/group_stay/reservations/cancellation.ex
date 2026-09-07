defmodule GroupStay.Reservations.Cancellation do
  @moduledoc """
  Settles cash and credit independently under the group's fixed policy. Only
  newly converted cash earns a bonus; restored credit keeps its original terms.
  """

  alias GroupStay.Credit
  alias GroupStay.Reservations.{CancellationPolicy, Group}

  def settle(group, operation, on) do
    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, on)

    with :ok <- validate_method(method, refundable?),
         {:ok, issued} <- issue_credit(group, operation["operation_id"], method, on) do
      cash = Group.cash_paid(group)
      refunded = if refundable? and method == "cash", do: cash, else: 0
      retained = if refundable?, do: 0, else: cash
      converted = if method == "hotel_credit", do: cash, else: 0

      Credit.settle_group(group, refundable?, on)

      {:ok,
       %{
         status: "cancelled",
         deposit_due_cents: 0,
         deposit_paid_cents: 0,
         credit_paid_cents: 0,
         cash_refunded_cents: refunded,
         cash_retained_cents: retained,
         cash_converted_to_credit_cents: converted
       }, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
    end
  end

  defp validate_method("hotel_credit", false), do: {:error, "refund_method_not_available"}
  defp validate_method(method, _) when method in ["cash", "hotel_credit"], do: :ok
  defp validate_method(_, _), do: {:error, "invalid_operation"}

  defp issue_credit(group, operation_id, "hotel_credit", on),
    do: Credit.issue(group.guest_id, operation_id, Group.cash_paid(group), on)

  defp issue_credit(_group, _operation_id, "cash", _on), do: {:ok, 0}
end
