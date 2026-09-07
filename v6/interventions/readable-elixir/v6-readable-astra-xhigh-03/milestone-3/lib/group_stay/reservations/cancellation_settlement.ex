defmodule GroupStay.Reservations.CancellationSettlement do
  @moduledoc """
  Separates cash disposition from the return or consumption of redeemed credit.

  Only cash receives the hotel-credit bonus. Previously redeemed credit always
  keeps its original lot and expiry, even when cash is converted alongside it.
  """

  alias GroupStay.Reservations.{CancellationPolicy, Group}

  defstruct refunded_cents: 0,
            retained_cents: 0,
            cash_converted_to_credit_cents: 0,
            credit_issued_cents: 0,
            restore_credit?: false

  def calculate(group, occurred_on, refund_method) do
    refundable? = CancellationPolicy.refundable?(group, occurred_on)
    cash = Group.cash_paid(group)

    cond do
      refund_method not in ["cash", "hotel_credit"] ->
        {:error, :invalid_operation}

      not refundable? and refund_method == "hotel_credit" ->
        {:error, :refund_method_not_available}

      not refundable? ->
        {:ok, %__MODULE__{retained_cents: cash}}

      refund_method == "hotel_credit" ->
        {:ok,
         %__MODULE__{
           cash_converted_to_credit_cents: cash,
           credit_issued_cents: cash + div(cash * 10 + 50, 100),
           restore_credit?: true
         }}

      true ->
        {:ok, %__MODULE__{refunded_cents: cash, restore_credit?: true}}
    end
  end

  def result(settlement) do
    Map.take(settlement, [:refunded_cents, :retained_cents, :credit_issued_cents])
  end
end
