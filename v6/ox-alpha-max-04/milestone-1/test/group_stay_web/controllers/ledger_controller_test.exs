defmodule GroupStayWeb.Controllers.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: true

  describe "GET /api/v1/ledger" do
    test "starts at zero before any cash moves", %{conn: conn} do
      assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0
             }
    end

    test "counts cash applied to active reservations as held", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-a"}),
          open_group_operation(%{"group_id" => "group-b"}),
          payment_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-a",
            "amount_cents" => 3_000
          }),
          payment_operation(%{
            "operation_id" => "op-4",
            "group_id" => "group-b",
            "amount_cents" => 4_000
          })
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{"cash_held_cents" => 7_000, "cash_refunded_cents" => 0, "cash_retained_cents" => 0} =
               ledger(conn)
    end

    test "unpaid deposit requirements never appear in the totals", %{conn: conn} do
      _conn = post_operations(conn, [open_group_operation()])

      assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 0, "cash_retained_cents" => 0} =
               ledger(conn)
    end

    test "a refundable cancellation moves held cash to refunded", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"operation_id" => "op-2", "amount_cents" => 8_000}),
          cancel_operation(%{"operation_id" => "op-3", "occurred_on" => "2026-11-20"})
        ])

      assert %{"results" => [_, _, %{"refunded_cents" => 8_000, "retained_cents" => 0}]} =
               json_response(conn, 200)

      assert %{"cash_held_cents" => 0, "cash_refunded_cents" => 8_000, "cash_retained_cents" => 0} =
               ledger(conn)
    end

    test "a non-refundable cancellation moves held cash to retained", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{
            "group_id" => "group-ap",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          }),
          payment_operation(%{
            "operation_id" => "op-2",
            "group_id" => "group-ap",
            "amount_cents" => 45_000
          }),
          cancel_operation(%{"operation_id" => "op-3", "group_id" => "group-ap"})
        ])

      assert %{"results" => [_, _, %{"refunded_cents" => 0, "retained_cents" => 45_000}]} =
               json_response(conn, 200)

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 45_000
             } =
               ledger(conn)
    end

    test "cancellations across groups accumulate in their own buckets", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-a"}),
          open_group_operation(%{
            "group_id" => "group-b",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
          }),
          payment_operation(%{
            "operation_id" => "op-3",
            "group_id" => "group-a",
            "amount_cents" => 5_000
          }),
          payment_operation(%{
            "operation_id" => "op-4",
            "group_id" => "group-b",
            "amount_cents" => 45_000
          }),
          cancel_operation(%{
            "operation_id" => "op-5",
            "group_id" => "group-a",
            "occurred_on" => "2026-11-20"
          }),
          cancel_operation(%{"operation_id" => "op-6", "group_id" => "group-b"})
        ])

      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5_000,
               "cash_retained_cents" => 45_000
             } =
               ledger(conn)
    end
  end

  defp payment_operation(overrides) do
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

  defp ledger(conn) do
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)
    data
  end
end
