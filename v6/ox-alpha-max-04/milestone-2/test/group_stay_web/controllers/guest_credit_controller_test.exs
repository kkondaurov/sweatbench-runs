defmodule GroupStayWeb.Controllers.GuestCreditControllerTest do
  use GroupStayWeb.ConnCase, async: true

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "a guest without credit has none available", %{conn: conn} do
      assert %{"data" => data} = json_response(get(conn, "/api/v1/guests/guest-22/credit"), 200)

      assert data == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "renders issued lots with their remaining balance and expiry", %{conn: conn} do
      conn = issue_credit(conn, "group-source", "op-3", 5_555)

      assert %{"data" => data} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)

      assert data == %{
               "guest_id" => "guest-22",
               "available_cents" => 6_111,
               "lots" => [
                 %{
                   "source_operation_id" => "op-3",
                   "remaining_cents" => 6_111,
                   "expires_on" => "2027-11-21"
                 }
               ]
             }
    end

    test "omits expired lots as of the on date", %{conn: conn} do
      conn = issue_credit(conn, "group-source", "op-3", 5_000)

      # The lot is available through 2027-11-20 and expired on 2027-11-21.
      assert %{"data" => %{"available_cents" => 5_500}} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-21"), 200)
    end

    test "orders lots by expiry and then by source operation", %{conn: conn} do
      conn =
        conn
        |> issue_credit("group-b", "op-b", 1_000, "2026-11-20")
        |> issue_credit("group-c", "op-c", 1_000, "2026-11-19")
        |> issue_credit("group-a", "op-a", 1_000, "2025-12-31")

      assert %{"data" => data} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2026-12-01"), 200)

      assert %{
               "available_cents" => 3_300,
               "lots" => [
                 %{"source_operation_id" => "op-a", "expires_on" => "2027-01-01"},
                 %{"source_operation_id" => "op-c", "expires_on" => "2027-11-20"},
                 %{"source_operation_id" => "op-b", "expires_on" => "2027-11-21"}
               ]
             } = data
    end

    test "shows only the unapplied portion of a partially applied lot", %{conn: conn} do
      conn =
        conn
        |> issue_credit("group-source", "op-cancel-source", 10_000)
        |> post_operations([
          open_group_operation(%{
            "operation_id" => "op-open-target",
            "group_id" => "group-target"
          }),
          %{
            "operation_id" => "op-apply",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-25",
            "group_id" => "group-target",
            "amount_cents" => 4_000
          }
        ])

      assert %{"data" => %{"available_cents" => 7_000, "lots" => [%{"remaining_cents" => 7_000}]}} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit?on=2027-11-20"), 200)
    end

    test "omits exhausted lots", %{conn: conn} do
      conn =
        conn
        |> issue_credit("group-source", "op-cancel-source", 2_000)
        |> post_operations([
          open_group_operation(%{
            "operation_id" => "op-open-target",
            "group_id" => "group-target"
          }),
          %{
            "operation_id" => "op-apply",
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-11-25",
            "group_id" => "group-target",
            "amount_cents" => 2_200
          }
        ])

      assert %{"data" => %{"available_cents" => 0, "lots" => []}} =
               json_response(get(conn, "/api/v1/guests/guest-22/credit"), 200)

      assert %{"credit_paid_cents" => 2_200} = fetch_group!(conn, "group-target")
    end

    test "rejects an unusable on parameter with 422", %{conn: conn} do
      conn = get(conn, "/api/v1/guests/guest-22/credit?on=tomorrow")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  # Cancels a refundable flexible group with `hotel_credit`, leaving guest-22
  # with a lot worth 110% of the cash, issued by `operation_id`. Cancelling on
  # the default date 2026-11-20 makes the lot expire on 2027-11-21.
  defp issue_credit(conn, group_id, operation_id, cash_cents, occurred_on \\ "2026-11-20") do
    post_operations(conn, [
      open_group_operation(%{"group_id" => group_id}),
      record_payment_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id <> "-pay",
        "amount_cents" => cash_cents
      }),
      cancel_operation(%{
        "group_id" => group_id,
        "operation_id" => operation_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp record_payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-01",
        "group_id" => "group-81"
      },
      overrides
    )
  end
end
