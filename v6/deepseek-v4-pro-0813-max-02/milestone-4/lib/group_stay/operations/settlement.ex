defmodule GroupStay.Operations.Settlement do
  @moduledoc """
  Shared validation for the operations that settle rooms: `cancel_group` and
  `cancel_rooms`.
  """

  alias GroupStay.Policy

  @refund_methods ["cash", "hotel_credit"]

  @spec validate_refund_method(term()) :: {:ok, String.t()} | :refund_method_not_available
  def validate_refund_method(nil), do: {:ok, "cash"}

  def validate_refund_method(method) when method in @refund_methods, do: {:ok, method}

  def validate_refund_method(_method), do: :refund_method_not_available

  @spec assert_method_available(map(), String.t(), Date.t()) :: :ok | :refund_method_not_available
  def assert_method_available(group, "hotel_credit", occurred_on) do
    policy = Policy.for_group(group)

    if Policy.refundable?(policy, group.arrival_on, occurred_on) do
      :ok
    else
      :refund_method_not_available
    end
  end

  def assert_method_available(_group, _method, _occurred_on), do: :ok
end
