defmodule GroupStayWeb.Controllers.LedgerControllerTest do
  use GroupStayWeb.ConnCase, async: true

  describe "GET /api/v1/ledger" do
    test "starts at zero before any cash moves", %{conn: conn} do
      assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger"), 200)

      assert data == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "counts cash applied to active reservations as held", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(%{"group_id" => "group-a", "operation_id" => "op-1"}),
          open_group_operation(%{"group_id" => "group-b", "operation_id" => "op-2"}),
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
          open_group_operation(%{"group_id" => "group-a", "operation_id" => "op-1"}),
          open_group_operation(%{
            "group_id" => "group-b",
            "operation_id" => "op-2",
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

  describe "credit liability" do
    test "tracks credit through conversion, application, and settlement", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"operation_id" => "op-2", "amount_cents" => 8_000}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, %{"credit_issued_cents" => 8_800}]} = json_response(conn, 200)

      assert %{"credit_liability_cents" => 8_800, "cash_converted_to_credit_cents" => 8_000} =
               ledger(conn)

      # Applying credit moves the lot into the active deposit without
      # changing the liability; a non-refundable cancellation consumes it.
      conn =
        post_operations(conn, [
          open_group_operation(%{"operation_id" => "op-4", "group_id" => "group-b"}),
          payment_operation(%{
            "operation_id" => "op-5",
            "group_id" => "group-b",
            "amount_cents" => 2_000
          }),
          credit_application(%{
            "operation_id" => "op-6",
            "group_id" => "group-b",
            "amount_cents" => 3_000
          }),
          cancel_operation(%{
            "operation_id" => "op-7",
            "group_id" => "group-b",
            "occurred_on" => "2026-11-27"
          })
        ])

      assert %{"results" => [_, _, _, %{"retained_cents" => 2_000}]} = json_response(conn, 200)

      assert ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 2_000,
               "cash_converted_to_credit_cents" => 8_000,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 5_800,
               "credit_shortfall_cents" => 0
             }
    end

    test "reports credit expiry as of the on parameter", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_group_operation(),
          payment_operation(%{"operation_id" => "op-2", "amount_cents" => 8_000}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"credit_liability_cents" => 8_800} = ledger(conn, on: "2027-11-20")
      assert %{"credit_liability_cents" => 0} = ledger(conn, on: "2027-11-21")
      assert %{"credit_liability_cents" => 0} = ledger(conn, on: "2031-01-01")
    end

    test "without on, expiry is evaluated as of the current UTC date", %{conn: conn} do
      today = Date.utc_today()

      conn =
        post_operations(conn, [
          open_group_operation(%{
            "occurred_on" => today |> Date.add(-15) |> Date.to_iso8601(),
            "arrival_on" => today |> Date.add(30) |> Date.to_iso8601(),
            "departure_on" => today |> Date.add(33) |> Date.to_iso8601()
          }),
          payment_operation(%{"operation_id" => "op-2", "amount_cents" => 8_000}),
          cancel_operation(%{
            "operation_id" => "op-3",
            "occurred_on" => today |> Date.add(-10) |> Date.to_iso8601(),
            "refund_method" => "hotel_credit"
          })
        ])

      assert %{"results" => [_, _, %{"status" => "applied", "credit_issued_cents" => 8_800}]} =
               json_response(conn, 200)

      # The lot was issued 10 days ago and expires 366 days after issue, so it
      # still counts today and the day before it expires, but not on the
      # expiry date itself.
      assert %{"credit_liability_cents" => 8_800} = ledger(conn)

      assert %{"credit_liability_cents" => 8_800} =
               ledger(conn, on: today |> Date.add(355) |> Date.to_iso8601())

      assert %{"credit_liability_cents" => 0} =
               ledger(conn, on: today |> Date.add(356) |> Date.to_iso8601())
    end

    test "rejects an unusable on parameter with 422", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger?on=not-a-date")
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp credit_application(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-apply",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-25",
        "group_id" => "group-81",
        "amount_cents" => 3_000
      },
      overrides
    )
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

  defp ledger(conn, opts \\ []) do
    query = if on = opts[:on], do: "?on=#{on}", else: ""
    assert %{"data" => data} = json_response(get(conn, "/api/v1/ledger#{query}"), 200)
    data
  end
end
