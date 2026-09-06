defmodule GroupStay.PartnerHelpers do
  @moduledoc false

  # Helpers for driving the partner API from tests.

  import Phoenix.ConnTest

  @endpoint GroupStayWeb.Endpoint

  def post_batch(operations),
    do: post(build_conn(), "/api/v1/partner-batches", %{"operations" => operations})

  def post_invalid_batch(body), do: post(build_conn(), "/api/v1/partner-batches", body)

  def results(conn), do: json_response(conn, 200)["results"]

  def result_for(conn, operation_id) do
    Enum.find(results(conn), &(&1["operation_id"] == operation_id))
  end

  def get_group(group_id), do: get(build_conn(), "/api/v1/groups/" <> group_id)

  def get_ledger(on \\ nil) do
    case on do
      nil -> get(build_conn(), "/api/v1/ledger")
      date -> get(build_conn(), "/api/v1/ledger", %{"on" => date})
    end
  end

  def get_guest_credit(guest_id, on \\ nil) do
    case on do
      nil -> get(build_conn(), "/api/v1/guests/" <> guest_id <> "/credit")
      date -> get(build_conn(), "/api/v1/guests/" <> guest_id <> "/credit", %{"on" => date})
    end
  end

  def open_group_operation(operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
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
      },
      overrides
    )
  end

  def pay_operation(operation_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def reschedule_operation(operation_id, group_id, new_arrival_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "reschedule_group",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "new_arrival_on" => new_arrival_on
      },
      overrides
    )
  end

  def cancel_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id
      },
      overrides
    )
  end

  def apply_credit_operation(operation_id, group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end
end
