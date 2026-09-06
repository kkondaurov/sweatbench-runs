defmodule GroupStay.PartnerHelpers do
  @moduledoc false

  # Helpers for driving the partner API from tests.

  import Plug.Conn
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

  def get_operation(operation_id), do: get(build_conn(), "/api/v1/operations/" <> operation_id)

  def get_payment(payment_operation_id),
    do: get(build_conn(), "/api/v1/payments/" <> payment_operation_id)

  def post_batch_json(raw_json) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", raw_json)
  end

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

  def get_daily_report(date \\ nil) do
    case date do
      nil -> get(build_conn(), "/api/v1/finance/daily-report")
      date -> get(build_conn(), "/api/v1/finance/daily-report", %{"date" => date})
    end
  end

  def start_reporting_operation(operation_id, starts_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => starts_on
      },
      overrides
    )
  end

  def close_period_operation(operation_id, period_end_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "close_finance_period",
        "occurred_on" => "2026-11-30",
        "period_end_on" => period_end_on
      },
      overrides
    )
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

  def cancel_rooms_operation(operation_id, group_id, room_ids, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_rooms",
        "occurred_on" => "2026-11-20",
        "group_id" => group_id,
        "room_ids" => room_ids
      },
      overrides
    )
  end

  def reduce_cash_operation(operation_id, payment_operation_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-11-20",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  def charge_back_operation(operation_id, payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-20",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  def transfer_operation(
        operation_id,
        source_group_id,
        destination_group_id,
        amount_cents,
        overrides \\ %{}
      ) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-20",
        "source_group_id" => source_group_id,
        "destination_group_id" => destination_group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end
end
