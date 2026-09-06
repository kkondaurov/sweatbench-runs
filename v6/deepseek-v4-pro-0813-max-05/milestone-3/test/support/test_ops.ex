defmodule GroupStay.TestOps do
  @moduledoc false
  # JSON-ready operation builders used across controller tests.

  @endpoint GroupStayWeb.Endpoint

  import ExUnit.Assertions
  import Phoenix.ConnTest

  def open_group(overrides \\ %{}) do
    %{
      "operation_id" => "op-open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
    |> Map.merge(overrides)
  end

  def payment(overrides \\ %{}) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-11-01",
      "group_id" => "group-81",
      "amount_cents" => 10_000
    }
    |> Map.merge(overrides)
  end

  def reschedule(overrides \\ %{}) do
    %{
      "operation_id" => "op-reschedule",
      "type" => "reschedule_group",
      "occurred_on" => "2026-11-15",
      "group_id" => "group-81",
      "new_arrival_on" => "2027-01-04"
    }
    |> Map.merge(overrides)
  end

  def cancel(overrides \\ %{}) do
    %{
      "operation_id" => "op-cancel",
      "type" => "cancel_group",
      "occurred_on" => "2026-11-20",
      "group_id" => "group-81"
    }
    |> Map.merge(overrides)
  end

  def apply_credit(overrides \\ %{}) do
    %{
      "operation_id" => "op-apply-credit",
      "type" => "apply_hotel_credit",
      "occurred_on" => "2026-11-27",
      "group_id" => "group-81",
      "amount_cents" => 5_000
    }
    |> Map.merge(overrides)
  end

  def submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  def open_group!(conn, overrides \\ %{}) do
    conn = submit(conn, [open_group(overrides)])
    [op_result] = json_response(conn, 200)["results"]
    assert op_result["status"] == "applied"
    assert op_result["group_id"] == Map.get(open_group(overrides), "group_id")
    conn
  end

  def json_post(conn, operation) do
    post(conn, "/api/v1/partner-batches", %{"operations" => [operation]})
  end

  def groups_path(group_id), do: "/api/v1/groups/#{group_id}"

  def guest_credit_path(guest_id), do: "/api/v1/guests/#{guest_id}/credit"
end
