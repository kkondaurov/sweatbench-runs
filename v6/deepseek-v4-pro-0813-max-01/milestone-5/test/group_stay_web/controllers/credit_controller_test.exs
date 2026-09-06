defmodule GroupStayWeb.CreditControllerTest do
  use GroupStayWeb.ConnCase

  defp batch(conn, ops) do
    resp = post(conn, "/api/v1/partner-batches", %{"operations" => ops})
    Jason.decode!(resp.resp_body)["results"]
  end

  defp open(conn, group_id, guest_id, booked_on, arrival_on) do
    batch(conn, [
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => booked_on,
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => arrival_on,
        "departure_on" => arrival_on |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      }
    ])
  end

  defp issue_credit(conn, group_id, guest_id, booked_on, arrival_on, pay_cents, cancel_on, op_id) do
    open(conn, group_id, guest_id, booked_on, arrival_on)

    batch(conn, [
      %{
        "operation_id" => "pay-#{group_id}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => pay_cents
      },
      %{
        "operation_id" => op_id,
        "type" => "cancel_group",
        "occurred_on" => cancel_on,
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ])
  end

  defp credit(conn, guest_id, query \\ "") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit#{query}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  test "an unknown guest has no credit", %{conn: conn} do
    assert credit(conn, "guest-nowhere") == %{
             "guest_id" => "guest-nowhere",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "lists available lots ordered by expiry, then source operation id", %{conn: conn} do
    guest_id = "guest-order"

    issue_credit(conn, "c1", guest_id, "2026-06-01", "2026-12-15", 500, "2026-06-10", "lot-b")
    issue_credit(conn, "c2", guest_id, "2026-07-01", "2027-01-15", 2_000, "2026-07-05", "lot-c")

    assert credit(conn, guest_id, "?on=2026-07-06") == %{
             "guest_id" => guest_id,
             "available_cents" => 2_750,
             "lots" => [
               %{
                 "source_operation_id" => "lot-b",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-06-11"
               },
               %{
                 "source_operation_id" => "lot-c",
                 "remaining_cents" => 2_200,
                 "expires_on" => "2027-07-06"
               }
             ]
           }

    # Equal expiration dates are broken by source operation id.
    issue_credit(conn, "c3", guest_id, "2026-06-05", "2026-12-20", 550, "2026-06-10", "lot-a")

    assert Enum.map(credit(conn, guest_id, "?on=2026-07-06")["lots"], & &1["source_operation_id"]) ==
             ["lot-a", "lot-b", "lot-c"]
  end

  test "reports expiry as of the requested date", %{conn: conn} do
    guest_id = "guest-ondate"

    issue_credit(conn, "c4", guest_id, "2026-06-01", "2026-12-15", 1_000, "2026-06-10", "lot-exp")

    assert credit(conn, guest_id, "?on=2027-06-10")["available_cents"] == 1_100

    assert credit(conn, guest_id, "?on=2027-06-11") == %{
             "guest_id" => guest_id,
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "rejects unusable on dates", %{conn: conn} do
    assert get(conn, "/api/v1/guests/guest-22/credit?on=garbage") |> json_response(422) == %{
             "error" => %{"code" => "invalid_date"}
           }
  end
end
