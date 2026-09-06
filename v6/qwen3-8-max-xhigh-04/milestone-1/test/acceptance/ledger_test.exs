defmodule GroupStayWeb.Acceptance.LedgerTest do
  use GroupStayWeb.ConnCase

  defp ledger(conn) do
    conn
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(group_id, rate_plan \\ "flexible") do
    %{
      "operation_id" => "open-#{group_id}",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => rate_plan,
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
    }
  end

  defp pay_op(group_id, amount_cents) do
    %{
      "operation_id" => "pay-#{group_id}-#{amount_cents}",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(group_id, occurred_on) do
    %{
      "operation_id" => "cancel-#{group_id}",
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => group_id
    }
  end

  test "starts with zero totals" do
    assert ledger(build_conn()) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "cash applied to active reservations is held cash" do
    submit(build_conn(), [
      open_op("group-a"),
      open_op("group-b"),
      pay_op("group-a", 2000),
      pay_op("group-b", 3000)
    ])

    assert ledger(build_conn()) == %{
             "cash_held_cents" => 5000,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "a refundable cancellation moves held cash to refunded" do
    submit(build_conn(), [open_op("group-a"), pay_op("group-a", 2000)])
    submit(build_conn(), [cancel_op("group-a", "2026-11-26")])

    assert ledger(build_conn()) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 2000,
             "cash_retained_cents" => 0
           }
  end

  test "a non-refundable cancellation moves held cash to retained" do
    submit(build_conn(), [open_op("group-a"), pay_op("group-a", 2000)])
    submit(build_conn(), [cancel_op("group-a", "2026-12-05")])

    assert ledger(build_conn()) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 2000
           }
  end

  test "an advance-purchase cancellation always retains cash" do
    submit(build_conn(), [open_op("group-a", "advance_purchase"), pay_op("group-a", 2000)])
    submit(build_conn(), [cancel_op("group-a", "2026-10-04")])

    assert ledger(build_conn()) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 2000
           }
  end

  test "unpaid deposit requirements never appear in the totals" do
    submit(build_conn(), [open_op("group-a")])

    assert ledger(build_conn()) == %{
             "cash_held_cents" => 0,
             "cash_refunded_cents" => 0,
             "cash_retained_cents" => 0
           }
  end

  test "totals accumulate across groups in different states" do
    submit(build_conn(), [
      open_op("group-a"),
      open_op("group-b"),
      open_op("group-c"),
      pay_op("group-a", 1000),
      pay_op("group-b", 1500),
      pay_op("group-c", 900)
    ])

    submit(build_conn(), [
      cancel_op("group-b", "2026-11-26"),
      cancel_op("group-c", "2026-12-05")
    ])

    assert ledger(build_conn()) == %{
             "cash_held_cents" => 1000,
             "cash_refunded_cents" => 1500,
             "cash_retained_cents" => 900
           }
  end
end
