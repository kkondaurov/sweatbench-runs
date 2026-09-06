defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"

  defp submit(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, group_id, overrides \\ %{}) do
    {conn, [result]} =
      submit(conn, [
        Map.merge(
          %{
            "operation_id" => "open-#{group_id}",
            "type" => "open_group",
            "occurred_on" => "2026-10-03",
            "group_id" => group_id,
            "guest_id" => "guest-22",
            "property_id" => "ams-canal",
            "arrival_on" => "2026-12-10",
            "departure_on" => "2026-12-13",
            "rate_plan" => "flexible",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
          },
          overrides
        )
      ])

    assert result["status"] == "applied"
    conn
  end

  defp pay(conn, group_id, amount_cents) do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "pay-#{group_id}-#{amount_cents}",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp cancel_for_credit(conn, group_id, cancel_id, occurred_on \\ "2026-10-04") do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => cancel_id,
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "refund_method" => "hotel_credit"
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp apply_credit(conn, group_id, amount_cents) do
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "credit-#{group_id}-#{amount_cents}",
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-05",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  defp credit(conn, guest_id, params \\ %{}) do
    conn = get(conn, "/api/v1/guests/#{guest_id}/credit", params)
    {conn, json_response(conn, 200)["data"]}
  end

  test "returns empty credit for a guest with no lots", %{conn: conn} do
    {_conn, data} = credit(conn, "guest-none")

    assert data == %{
             "guest_id" => "guest-none",
             "available_cents" => 0,
             "lots" => []
           }
  end

  test "returns the documented lot shape", %{conn: conn} do
    conn =
      open_group(conn, "group-a", %{
        "occurred_on" => "2027-05-02",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      })

    conn = pay(conn, "group-a", 5500)
    conn = cancel_for_credit(conn, "group-a", "cancel-17", "2027-05-02")

    {_conn, data} = credit(conn, "guest-22", %{"on" => "2027-05-02"})

    assert data == %{
             "guest_id" => "guest-22",
             "available_cents" => 6050,
             "lots" => [
               %{
                 "source_operation_id" => "cancel-17",
                 "remaining_cents" => 6050,
                 "expires_on" => "2028-05-02"
               }
             ]
           }
  end

  test "omits exhausted lots until they are restored", %{conn: conn} do
    conn = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 2000)
    conn = cancel_for_credit(conn, "group-a", "cancel-17")
    conn = open_group(conn, "group-b")
    conn = apply_credit(conn, "group-b", 2200)

    {conn, data} = credit(conn, "guest-22", %{"on" => "2026-10-06"})
    assert data["available_cents"] == 0
    assert data["lots"] == []

    # refundable cancellation restores the exhausted lot
    {conn, [result]} =
      submit(conn, [
        %{
          "operation_id" => "settle-b",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-06",
          "group_id" => "group-b"
        }
      ])

    assert result["status"] == "applied"

    {_conn, restored} = credit(conn, "guest-22", %{"on" => "2026-10-06"})
    assert restored["available_cents"] == 2200
    assert [%{"source_operation_id" => "cancel-17", "remaining_cents" => 2200}] = restored["lots"]
  end

  test "omits expired lots as of the on date", %{conn: conn} do
    conn = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 2000)
    conn = cancel_for_credit(conn, "group-a", "cancel-17")

    {conn, available} = credit(conn, "guest-22", %{"on" => "2027-10-04"})
    assert available["available_cents"] == 2200

    {_conn, expired} = credit(conn, "guest-22", %{"on" => "2027-10-05"})
    assert expired["available_cents"] == 0
    assert expired["lots"] == []
  end

  test "orders lots by expiry, then by source operation", %{conn: conn} do
    conn = open_group(conn, "group-a")
    conn = pay(conn, "group-a", 1000)
    conn = cancel_for_credit(conn, "group-a", "cancel-b", "2026-10-04")

    conn = open_group(conn, "group-b")
    conn = pay(conn, "group-b", 1000)
    conn = cancel_for_credit(conn, "group-b", "cancel-a", "2026-10-04")

    conn = open_group(conn, "group-c")
    conn = pay(conn, "group-c", 1000)
    conn = cancel_for_credit(conn, "group-c", "cancel-c", "2026-10-01")

    {_conn, data} = credit(conn, "guest-22", %{"on" => "2026-10-04"})

    assert Enum.map(data["lots"], & &1["source_operation_id"]) ==
             ~w(cancel-c cancel-a cancel-b)

    assert Enum.map(data["lots"], & &1["expires_on"]) ==
             ~w(2027-10-02 2027-10-05 2027-10-05)
  end

  test "defaults to the current UTC date", %{conn: conn} do
    today = Date.utc_today()
    expires_today = Date.add(today, -366)
    expires_tomorrow = Date.add(today, -365)

    for {group_id, cancel_date} <- [{"group-a", expires_today}, {"group-b", expires_tomorrow}] do
      conn =
        open_group(conn, group_id, %{
          "occurred_on" => Date.to_string(cancel_date),
          "arrival_on" => Date.to_string(Date.add(cancel_date, 60)),
          "departure_on" => Date.to_string(Date.add(cancel_date, 63))
        })

      conn = pay(conn, group_id, 1000)
      cancel_for_credit(conn, group_id, "cancel-#{group_id}", Date.to_string(cancel_date))
    end

    {_conn, data} = credit(conn, "guest-22")

    assert data["available_cents"] == 1100
    assert [%{"source_operation_id" => "cancel-group-b"}] = data["lots"]
  end

  test "rejects an unusable on parameter", %{conn: conn} do
    for params <- [%{"on" => "not-a-date"}, %{"on" => "2026-13-01"}, %{"on" => 42}] do
      conn = get(conn, "/api/v1/guests/guest-22/credit", params)
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
