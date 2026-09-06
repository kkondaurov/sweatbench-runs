defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-02-01",
        "departure_on" => "2027-02-02",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
      },
      overrides
    )
  end

  # Opens, funds, and cancels a flexible group into a credit lot of
  # `cash_cents` + 10%, expiring 365 days after `cancelled_on`.
  defp issue_lot(
         conn,
         group_id,
         source_operation_id,
         cash_cents,
         cancelled_on,
         open_overrides \\ %{}
       ) do
    operations = [
      open_op(group_id, open_overrides),
      %{
        "operation_id" => "op-pay-#{group_id}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      },
      %{
        "operation_id" => source_operation_id,
        "type" => "cancel_group",
        "occurred_on" => cancelled_on,
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})
    assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)
  end

  test "returns an empty position for a guest without credit", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/guests/guest-unknown/credit")

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-unknown", "available_cents" => 0, "lots" => []}
           }
  end

  test "lists live lots ordered by expiry, then source operation", %{conn: conn} do
    # later expiry but an earlier source operation id
    issue_lot(conn, "group-81", "cancel-a", 1_000, "2027-01-01")
    # earlier expiry, listed first despite the later source id
    issue_lot(build_conn(), "group-82", "cancel-b", 2_000, "2026-12-01")

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2027-06-01")

    assert json_response(conn, 200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 1_100 + 2_200,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-b",
                   "remaining_cents" => 2_200,
                   "expires_on" => "2027-12-01"
                 },
                 %{
                   "source_operation_id" => "cancel-a",
                   "remaining_cents" => 1_100,
                   "expires_on" => "2028-01-01"
                 }
               ]
             }
           }
  end

  test "reports expiry as of the on date, keeping lots through their expires_on date",
       %{conn: conn} do
    issue_lot(conn, "group-81", "cancel-a", 1_000, "2026-12-01")

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2027-12-01")
    assert %{"data" => %{"available_cents" => 1_100}} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=2027-12-02")

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }
  end

  test "omits exhausted lots", %{conn: conn} do
    issue_lot(conn, "group-81", "cancel-a", 1_000, "2026-12-01")

    operations = [
      open_op("group-82", %{
        "occurred_on" => "2027-06-01",
        "arrival_on" => "2027-09-01",
        "departure_on" => "2027-09-02"
      }),
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2027-06-02",
        "group_id" => "group-82",
        "amount_cents" => 1_100
      }
    ]

    conn = post_batch(build_conn(), %{"operations" => operations})
    assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit")

    assert json_response(conn, 200) == %{
             "data" => %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
           }
  end

  test "an unusable on date falls back to the current date", %{conn: conn} do
    issue_lot(conn, "group-81", "cancel-a", 1_000, "2039-01-01", %{
      "arrival_on" => "2039-03-01",
      "departure_on" => "2039-03-02"
    })

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit?on=not-a-date")
    assert %{"data" => %{"available_cents" => 1_100}} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/v1/guests/guest-22/credit")
    assert %{"data" => %{"available_cents" => 1_100}} = json_response(conn, 200)
  end
end
