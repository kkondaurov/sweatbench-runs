defmodule GroupStayWeb.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase

  import GroupStay.BatchHelpers

  # Opens group-81 for guest-22, funds it with cash, and cancels it choosing
  # hotel credit on 2026-11-01: a lot of 110% of the cash, expiring
  # 2027-11-02.
  defp issue_credit!(conn, cash_cents, cancel_overrides \\ %{}) do
    apply_batch!(conn, [
      open_group_op(),
      record_cash_payment_op(%{"amount_cents" => cash_cents})
    ])

    apply_batch!(fresh_conn(), [
      cancel_group_op(Map.merge(%{"refund_method" => "hotel_credit"}, cancel_overrides))
    ])
  end

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "a guest without lots has no available credit", %{conn: conn} do
      data = get_credit!(conn, "guest-unknown")

      assert data == %{"guest_id" => "guest-unknown", "available_cents" => 0, "lots" => []}
    end

    test "returns the lots issued by hotel-credit cancellations", %{conn: conn} do
      issue_credit!(conn, 19_500)

      data = get_credit!(fresh_conn(), "guest-22")

      assert data == %{
               "guest_id" => "guest-22",
               "available_cents" => 21_450,
               "lots" => [
                 %{
                   "source_operation_id" => "op-4001",
                   "remaining_cents" => 21_450,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }
    end

    test "only the cancelling guest holds the credit", %{conn: conn} do
      issue_credit!(conn, 19_500)

      assert get_credit!(fresh_conn(), "guest-other")["available_cents"] == 0
    end

    test "orders lots by expiry and then by source operation", %{conn: conn} do
      issue_credit!(conn, 10_000, %{
        "operation_id" => "op-later",
        "occurred_on" => "2026-11-05"
      })

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-91", "group_id" => "group-91"}),
        record_cash_payment_op(%{
          "operation_id" => "op-92",
          "group_id" => "group-91",
          "amount_cents" => 10_000
        }),
        cancel_group_op(%{
          "operation_id" => "op-sooner-b",
          "group_id" => "group-91",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      ])

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-93", "group_id" => "group-93"}),
        record_cash_payment_op(%{
          "operation_id" => "op-94",
          "group_id" => "group-93",
          "amount_cents" => 10_000
        }),
        cancel_group_op(%{
          "operation_id" => "op-sooner-a",
          "group_id" => "group-93",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      ])

      data = get_credit!(fresh_conn(), "guest-22")

      assert Enum.map(data["lots"], & &1["source_operation_id"]) == [
               "op-sooner-a",
               "op-sooner-b",
               "op-later"
             ]

      assert Enum.map(data["lots"], & &1["expires_on"]) == [
               "2027-11-02",
               "2027-11-02",
               "2027-11-06"
             ]
    end

    test "omits exhausted lots", %{conn: conn} do
      issue_credit!(conn, 19_500)

      apply_batch!(fresh_conn(), [
        open_group_op(%{
          "operation_id" => "op-82",
          "group_id" => "group-82",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 35_750}]
        }),
        apply_hotel_credit_op(%{"amount_cents" => 21_450})
      ])

      data = get_credit!(fresh_conn(), "guest-22")
      assert data["available_cents"] == 0
      assert data["lots"] == []
    end

    test "omits lots expired as of the requested date", %{conn: conn} do
      issue_credit!(conn, 19_500)

      # The lot is available through 2027-11-01 and expires on 2027-11-02.
      assert get_credit!(fresh_conn(), "guest-22", "2027-11-01")["available_cents"] == 21_450
      assert get_credit!(fresh_conn(), "guest-22", "2027-11-02")["available_cents"] == 0
      assert get_credit!(fresh_conn(), "guest-22", "2027-11-02")["lots"] == []
    end

    test "credit applied to an active group is not available", %{conn: conn} do
      issue_credit!(conn, 19_500)

      apply_batch!(fresh_conn(), [
        open_group_op(%{"operation_id" => "op-82", "group_id" => "group-82"}),
        apply_hotel_credit_op(%{"amount_cents" => 19_500})
      ])

      data = get_credit!(fresh_conn(), "guest-22")

      assert data["available_cents"] == 1_950
      assert [%{"remaining_cents" => 1_950}] = data["lots"]
    end

    test "an unusable on parameter falls back to the current date", %{conn: conn} do
      issue_credit!(conn, 19_500)

      conn
      |> get(~p"/api/v1/guests/guest-22/credit?on=not-a-date")
      |> json_response(200)
    end
  end
end
