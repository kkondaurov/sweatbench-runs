defmodule GroupStay.Policies do
  @moduledoc false

  @cutover ~D[2027-01-01]

  @spec policy_version(String.t(), Date.t()) :: String.t()
  def policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version("flexible", booked_on) do
    case Date.compare(booked_on, @cutover) do
      :lt -> "flex-14"
      _ -> "flex-30"
    end
  end

  @spec refundable_until(String.t(), Date.t()) :: Date.t() | nil
  def refundable_until("advance-nonrefundable", _arrival_on), do: nil

  def refundable_until(version, arrival_on) do
    Date.add(arrival_on, -window_days(version))
  end

  @spec refundable?(String.t(), Date.t(), Date.t()) :: boolean()
  def refundable?(version, arrival_on, occurred_on) do
    case refundable_until(version, arrival_on) do
      nil -> false
      until_on -> Date.compare(occurred_on, until_on) in [:lt, :eq]
    end
  end

  defp window_days("flex-14"), do: 14
  defp window_days("flex-30"), do: 30
end
