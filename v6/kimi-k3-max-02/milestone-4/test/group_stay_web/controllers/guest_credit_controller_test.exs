defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp credit(conn, guest_id) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp credit_on(conn, guest_id, on) do
    conn
    |> get(~p"/api/v1/guests/#{guest_id}/credit?on=#{on}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Issues a credit lot for guest-22 by opening a group, funding it with cash,
  # and cancelling it refundably with refund_method hotel_credit.
  defp issue_lot!(conn, group_id, operation_id, cash_cents, occurred_on, open_overrides \\ %{}) do
    open_operation =
      Map.merge(
        %{
          "operation_id" => "op-open-#{group_id}",
          "type" => "open_group",
          "occurred_on" => "2026-10-03",
          "group_id" => group_id,
          "guest_id" => "guest-22",
          "property_id" => "ams-canal",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-13",
          "rate_plan" => "flexible",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15000}]
        },
        open_overrides
      )

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             post_batch(conn, [
               open_operation,
               %{
                 "operation_id" => "op-pay-#{group_id}",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => group_id,
                 "amount_cents" => cash_cents
               },
               %{
                 "operation_id" => operation_id,
                 "type" => "cancel_group",
                 "occurred_on" => occurred_on,
                 "group_id" => group_id,
                 "refund_method" => "hotel_credit"
               }
             ])
  end

  test "a guest without lots has no available credit", %{conn: conn} do
    assert credit(conn, "guest-nobody") == %{
             "guest_id" => "guest-nobody",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "lists lots with their source operation, remaining amount, and expiry", %{conn: conn} do
    issue_lot!(conn, "group-81", "op-cancel-17", 5000, "2026-11-26")

    assert credit_on(conn, "guest-22", "2027-01-01") == %{
             "guest_id" => "guest-22",
             "available_cents" => 5500,
             "lots" => [
               %{
                 "source_operation_id" => "op-cancel-17",
                 "remaining_cents" => 5500,
                 "expires_on" => "2027-11-26"
               }
             ]
           }
  end

  test "lots are ordered by expires_on, then by source_operation_id", %{conn: conn} do
    issue_lot!(conn, "group-b", "op-cancel-b", 1000, "2026-11-26")
    issue_lot!(conn, "group-z", "op-cancel-z", 1000, "2026-11-20")
    issue_lot!(conn, "group-a", "op-cancel-a", 1000, "2026-11-26")

    assert credit_on(conn, "guest-22", "2027-01-01")["lots"] == [
             %{
               "source_operation_id" => "op-cancel-z",
               "remaining_cents" => 1100,
               "expires_on" => "2027-11-20"
             },
             %{
               "source_operation_id" => "op-cancel-a",
               "remaining_cents" => 1100,
               "expires_on" => "2027-11-26"
             },
             %{
               "source_operation_id" => "op-cancel-b",
               "remaining_cents" => 1100,
               "expires_on" => "2027-11-26"
             }
           ]
  end

  test "a lot is available through its expiry date and omitted the day after", %{conn: conn} do
    issue_lot!(conn, "group-81", "op-cancel-17", 5000, "2026-11-26")

    assert credit_on(conn, "guest-22", "2027-11-26")["available_cents"] == 5500

    assert credit_on(conn, "guest-22", "2027-11-27") == %{
             "guest_id" => "guest-22",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "exhausted lots are omitted", %{conn: conn} do
    issue_lot!(conn, "group-81", "op-cancel-17", 5000, "2026-11-26")

    # a group whose deposit swallows the whole lot
    assert [%{"status" => "applied"}, %{"status" => "applied"}] =
             post_batch(conn, [
               %{
                 "operation_id" => "op-open-100",
                 "type" => "open_group",
                 "occurred_on" => "2026-10-03",
                 "group_id" => "group-100",
                 "guest_id" => "guest-22",
                 "property_id" => "ams-canal",
                 "arrival_on" => "2026-12-10",
                 "departure_on" => "2026-12-13",
                 "rate_plan" => "flexible",
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
                 ]
               },
               %{
                 "operation_id" => "op-apply",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-100",
                 "amount_cents" => 5500
               }
             ])

    assert credit_on(conn, "guest-22", "2027-01-01")["lots"] == []
  end

  test "without an on parameter, the current UTC date decides expiry", %{conn: conn} do
    # expires 2036-12-31 (2036 is a leap year): available whenever the suite
    # runs in this era
    issue_lot!(conn, "group-future", "op-cancel-future", 5000, "2036-01-01", %{
      "occurred_on" => "2036-01-01",
      "arrival_on" => "2036-02-01",
      "departure_on" => "2036-02-03"
    })

    # expires 2021-01-01: long past whenever the suite runs
    issue_lot!(conn, "group-past", "op-cancel-past", 5000, "2020-01-01", %{
      "occurred_on" => "2020-01-01",
      "arrival_on" => "2020-02-01",
      "departure_on" => "2020-02-03"
    })

    assert credit(conn, "guest-22")["lots"] == [
             %{
               "source_operation_id" => "op-cancel-future",
               "remaining_cents" => 5500,
               "expires_on" => "2036-12-31"
             }
           ]
  end

  test "a malformed on date is rejected", %{conn: conn} do
    for on <- ["not-a-date", "2027-13-01", "20270101"] do
      response =
        conn
        |> get(~p"/api/v1/guests/guest-22/credit?on=#{on}")
        |> json_response(422)

      assert response == %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
