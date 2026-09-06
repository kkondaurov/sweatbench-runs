defmodule GroupStay.Acceptance.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"
  @starts_on "2026-10-10"
  @cutoff "2026-10-31"
  # The day after @cutoff: the first open day once that period is closed.
  @first_open_day "2026-11-01"
  # Arrival minus the flex-14 window; cancelling on this date is refundable.
  @refundable_on "2026-11-26"

  defp open_operation(group_id, opts \\ []) do
    %{
      "operation_id" => Keyword.get(opts, :operation_id, "op-open-#{group_id}"),
      "type" => "open_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @open_occurred_on),
      "group_id" => group_id,
      "guest_id" => Keyword.get(opts, :guest_id, "guest-22"),
      "property_id" => Keyword.get(opts, :property_id, "ams-canal"),
      "arrival_on" => Keyword.get(opts, :arrival_on, @arrival_on),
      "departure_on" => Keyword.get(opts, :departure_on, @departure_on),
      "rate_plan" => Keyword.get(opts, :rate_plan, "flexible"),
      "rooms" =>
        Keyword.get(opts, :rooms, [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ])
    }
  end

  defp cash_operation(operation_id, group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-12"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_operation(operation_id, group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-20"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(operation_id, group_id, opts) do
    operation = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => Keyword.get(opts, :occurred_on, @refundable_on),
      "group_id" => group_id
    }

    case Keyword.get(opts, :refund_method) do
      nil -> operation
      method -> Map.put(operation, "refund_method", method)
    end
  end

  defp transfer_operation(operation_id, source_group_id, destination_group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => "2026-10-14",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_operation(operation_id, payment_operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_operation(operation_id, payment_operation_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => payment_operation_id
    }
  end

  defp start_operation(operation_id, starts_on \\ @starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "occurred_on" => @starts_on,
      "starts_on" => starts_on
    }
  end

  defp close_operation(operation_id, period_end_on \\ @cutoff) do
    %{
      "operation_id" => operation_id,
      "type" => "close_finance_period",
      "occurred_on" => period_end_on,
      "period_end_on" => period_end_on
    }
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_report!(date) do
    build_conn()
    |> get("/api/v1/finance/daily-report?date=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_ledger! do
    build_conn()
    |> get("/api/v1/ledger")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_group!(group_id) do
    build_conn()
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_statement!(payment_operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_stored_result!(operation_id) do
    build_conn()
    |> get("/api/v1/operations/#{operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Zero-valued movements for comparisons against full movement maps.
  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp cash_movements(overrides), do: Map.merge(zero_cash_movements(), overrides)

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp credit_movements(overrides), do: Map.merge(zero_credit_movements(), overrides)

  defp no_late_adjustments do
    %{"cash" => [], "credit" => zero_credit_movements()}
  end

  describe "POST /api/v1/partner-batches with close_finance_period" do
    test "applies with exactly operation_id, status, and period_end_on", %{conn: conn} do
      assert [%{"status" => "applied"}] = post_batch(conn, [start_operation("op-start")])

      results = post_batch(conn, [close_operation("close-1")])

      assert [
               %{
                 "operation_id" => "close-1",
                 "status" => "applied",
                 "period_end_on" => @cutoff
               }
             ] = results

      assert map_size(hd(results)) == 3

      # The stored result is exactly the response the batch returned.
      assert %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => @cutoff
             } = get_stored_result!("close-1")
    end

    test "rejects a close before finance reporting has started", %{conn: conn} do
      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               post_batch(conn, [close_operation("close-1")])
    end

    test "rejects a period_end_on before starts_on", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               post_batch(conn, [close_operation("close-early", "2026-10-09")])
    end

    test "closes on starts_on itself and publishes that single day", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        cash_operation("pay-1", "group-81", 5_000),
        start_operation("op-start")
      ])

      assert [%{"status" => "applied", "period_end_on" => @starts_on}] =
               post_batch(conn, [close_operation("close-day-one", @starts_on)])

      assert %{"status" => "closed"} = get_report!(@starts_on)
      assert %{"status" => "open"} = get_report!("2026-10-11")
    end

    test "rejects a missing or unusable period_end_on as invalid_period", %{conn: conn} do
      post_batch(conn, [start_operation("op-start")])

      missing =
        close_operation("close-missing")
        |> Map.delete("period_end_on")

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               post_batch(conn, [missing])

      unusable =
        close_operation("close-unusable")
        |> Map.put("period_end_on", "31/10/2026")

      assert [%{"status" => "rejected", "code" => "invalid_period"}] =
               post_batch(conn, [unusable])

      # Nothing was closed by the rejected attempts.
      assert %{"status" => "open"} = get_report!(@starts_on)
    end

    test "an identical retry returns the exact stored result", %{conn: conn} do
      post_batch(conn, [start_operation("op-start")])

      first = [%{"status" => "applied"}] = post_batch(conn, [close_operation("close-1")])
      assert ^first = post_batch(conn, [close_operation("close-1")])

      # The replay does not disturb the published reports.
      assert %{"status" => "closed"} = get_report!(@starts_on)
    end

    test "a different operation attempting the same or an earlier cutoff is rejected", %{
      conn: conn
    } do
      post_batch(conn, [start_operation("op-start")])

      assert [%{"status" => "applied"}] = post_batch(conn, [close_operation("close-1")])

      assert [
               %{
                 "operation_id" => "close-same",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ] = post_batch(conn, [close_operation("close-same")])

      assert [
               %{
                 "operation_id" => "close-earlier",
                 "status" => "rejected",
                 "code" => "invalid_period"
               }
             ] = post_batch(conn, [close_operation("close-earlier", "2026-10-15")])

      # Neither rejection published anything new.
      assert %{"status" => "open"} = get_report!("2026-12-01")

      # A strictly later cutoff still applies.
      assert [%{"status" => "applied", "period_end_on" => "2026-11-30"}] =
               post_batch(conn, [close_operation("close-later", "2026-11-30")])

      assert %{"status" => "closed"} = get_report!("2026-11-30")
      assert %{"status" => "open"} = get_report!("2026-12-01")
    end

    test "reusing the identifier with a different cutoff is an operation_id_conflict", %{
      conn: conn
    } do
      post_batch(conn, [start_operation("op-start")])

      assert [%{"status" => "applied"}] = post_batch(conn, [close_operation("close-1")])

      conflicting = close_operation("close-1", "2026-11-30")

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               post_batch(conn, [conflicting])

      # The original record stands: only days through the first cutoff closed.
      assert %{"status" => "closed"} = get_report!(@cutoff)
      assert %{"status" => "open"} = get_report!("2026-11-30")
    end
  end

  describe "publishing reports" do
    test "publishes every report through the cutoff and leaves later days open", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start"),
        cash_operation("pay-1", "group-81", 5_000)
      ])

      before_close = get_report!("2026-10-15")
      assert %{"status" => "open"} = before_close

      assert [%{"status" => "applied"}] = post_batch(conn, [close_operation("close-1")])

      closed = get_report!("2026-10-15")
      assert %{"status" => "closed"} = closed
      assert closed == Map.put(before_close, "status", "closed")

      assert %{"status" => "closed"} = get_report!(@cutoff)
      assert %{"status" => "open"} = get_report!(@first_open_day)
      assert %{"status" => "open"} = get_report!("2027-08-01")
    end

    test "closed reports stay stable across later operations and later closes", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        open_operation("group-b", property_id: "rtm-harbor"),
        start_operation("op-start"),
        cash_operation("pay-1", "group-81", 5_000, occurred_on: "2026-10-12")
      ])

      ledger_before_close = get_ledger!()

      assert [%{"status" => "applied"}] = post_batch(conn, [close_operation("close-1")])

      snapshot_a = get_report!("2026-10-12")
      snapshot_b = get_report!(@starts_on)

      # Closing itself changes no current-state view.
      assert get_ledger!() == ledger_before_close

      # Later operations with dates inside the closed period must not touch it.
      post_batch(build_conn(), [
        cash_operation("pay-old", "group-b", 3_000, occurred_on: "2026-10-05"),
        cash_operation("pay-future", "group-81", 1_000, occurred_on: "2027-01-01")
      ])

      assert get_report!("2026-10-12") == snapshot_a
      assert get_report!(@starts_on) == snapshot_b

      # A second close extends coverage without rewriting published days.
      assert [%{"status" => "applied"}] =
               post_batch(build_conn(), [close_operation("close-2", "2027-02-28")])

      assert get_report!("2026-10-12") == snapshot_a
      assert %{"status" => "closed"} = get_report!(@first_open_day)
      assert %{"status" => "closed"} = get_report!("2027-01-01")
      assert %{"status" => "open"} = get_report!("2027-03-01")
    end

    test "closing changes no group, statement, or stored result view", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start"),
        cash_operation("pay-1", "group-81", 5_000)
      ])

      group_before = get_group!("group-81")
      ledger_before = get_ledger!()
      statement_before = get_statement!("pay-1")
      stored_before = get_stored_result!("pay-1")

      post_batch(conn, [close_operation("close-1")])

      assert get_group!("group-81") == group_before
      assert get_ledger!() == ledger_before
      assert get_statement!("pay-1") == statement_before
      assert get_stored_result!("pay-1") == stored_before
    end
  end

  describe "posting after a close" do
    test "an operation immediately before a close can post into the period being closed", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start"),
        cash_operation("pay-mid", "group-81", 4_000, occurred_on: "2026-10-20"),
        close_operation("close-1")
      ])

      report = get_report!("2026-10-20")

      assert %{"status" => "closed", "cash" => cash, "late_adjustments" => late} = report
      assert [%{"movements" => movements, "closing_held_cents" => 4_000}] = cash
      assert cash_movements(%{"received_cents" => 4_000}) == movements
      assert no_late_adjustments() == late
    end

    test "an old-dated operation immediately after a close posts complete on the first open day",
         %{
           conn: conn
         } do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      assert [%{"status" => "applied"}] = post_batch(conn, [close_operation("close-1")])

      post_batch(build_conn(), [
        cash_operation("pay-old", "group-81", 3_000, occurred_on: "2026-10-06")
      ])

      # The closed day stays untouched; the movement lands whole on the first
      # open day and is reported as a late adjustment there.
      assert %{"status" => "closed"} = get_report!(@cutoff)

      report = get_report!(@first_open_day)

      assert %{
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => movements,
                   "closing_held_cents" => 3_000
                 }
               ],
               "credit" => credit,
               "late_adjustments" => late
             } = report

      assert cash_movements(%{"received_cents" => 3_000}) == movements
      assert zero_credit_movements() == credit["movements"]

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => late_received
               }
             ] = late["cash"]

      assert cash_movements(%{"received_cents" => 3_000}) == late_received
      assert zero_credit_movements() == late["credit"]
    end

    test "an occurred_on already inside the open period keeps its date and is not late", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      post_batch(conn, [close_operation("close-1")])

      post_batch(build_conn(), [
        cash_operation("pay-open", "group-81", 2_000, occurred_on: "2026-11-05")
      ])

      report = get_report!("2026-11-05")

      assert %{"status" => "open", "cash" => cash, "late_adjustments" => late} = report

      assert [%{"movements" => movements}] = cash
      assert cash_movements(%{"received_cents" => 2_000}) == movements
      assert no_late_adjustments() == late
    end

    test "the posting date chosen at commit time survives a later close", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      post_batch(conn, [close_operation("close-1")])

      post_batch(build_conn(), [
        cash_operation("pay-late", "group-81", 3_000, occurred_on: "2026-10-06")
      ])

      late_day = get_report!(@first_open_day)
      assert %{"late_adjustments" => %{"cash" => [_entry]}} = late_day

      # Closing over the late day freezes it exactly as first reported.
      post_batch(build_conn(), [close_operation("close-2", "2026-11-30")])

      assert get_report!(@first_open_day) == Map.put(late_day, "status", "closed")
      assert %{"status" => "closed"} = get_report!("2026-11-30")
      assert %{"status" => "open"} = get_report!("2026-12-01")
    end
  end

  describe "identifying late adjustments" do
    test "keeps signed classifications even when they net to zero against each other", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start"),
        cash_operation("pay-1", "group-81", 9_000),
        cancel_operation("cancel-1", "group-81", refund_method: "cash")
      ])

      # Freeze the refunded day, then reverse the refund old-dated afterwards:
      # the reversal can only land on the first open day as a late adjustment.
      post_batch(conn, [close_operation("close-1", "2026-11-30")])

      post_batch(build_conn(), [
        charge_back_operation("chb-1", "pay-1", "2026-11-28")
      ])

      report = get_report!("2026-12-01")

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => movements,
                   "closing_held_cents" => 0
                 }
               ],
               "late_adjustments" => late
             } = report

      assert cash_movements(%{"refunded_cents" => -9_000, "charged_back_cents" => 9_000}) ==
               movements

      assert [
               %{
                 "property_id" => "ams-canal",
                 "movements" => reversal_late_movements
               }
             ] = late["cash"]

      assert cash_movements(%{"refunded_cents" => -9_000, "charged_back_cents" => 9_000}) ==
               reversal_late_movements

      assert zero_credit_movements() == late["credit"]
    end

    test "omits all-zero properties from late adjustments but keeps them in the cash array", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("group-src"),
        open_operation("group-dst", property_id: "rtm-harbor"),
        start_operation("op-start"),
        cash_operation("pay-1", "group-src", 12_000),
        transfer_operation("transfer-1", "group-src", "group-dst", 5_000)
      ])

      post_batch(conn, [close_operation("close-1")])

      # The reduction follows the transferred cash to rtm-harbor; ams-canal
      # sees nothing late on the day but still holds 7_000.
      post_batch(build_conn(), [reduce_operation("reduce-1", "pay-1", 3_000, "2026-10-16")])

      report = get_report!(@first_open_day)

      assert %{"cash" => cash, "late_adjustments" => late} = report

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 7_000,
                 "movements" => quiet_movements,
                 "closing_held_cents" => 7_000
               },
               %{
                 "property_id" => "rtm-harbor",
                 "opening_held_cents" => 5_000,
                 "movements" => reduced_movements,
                 "closing_held_cents" => 2_000
               }
             ] = cash

      assert zero_cash_movements() == quiet_movements
      assert cash_movements(%{"reduced_cents" => 3_000}) == reduced_movements

      assert [
               %{
                 "property_id" => "rtm-harbor",
                 "movements" => reduced_late_movements
               }
             ] = late["cash"]

      assert cash_movements(%{"reduced_cents" => 3_000}) == reduced_late_movements
      assert zero_credit_movements() == late["credit"]
    end

    test "charges back across properties in property order when posted late", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-src"),
        open_operation("group-dst", property_id: "rtm-harbor"),
        start_operation("op-start"),
        cash_operation("pay-1", "group-src", 12_000),
        transfer_operation("transfer-1", "group-src", "group-dst", 5_000)
      ])

      post_batch(conn, [close_operation("close-1")])

      post_batch(build_conn(), [charge_back_operation("chb-1", "pay-1", "2026-10-16")])

      report = get_report!(@first_open_day)

      assert %{"cash" => cash, "late_adjustments" => late} = report

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 7_000,
                 "movements" => %{"charged_back_cents" => 7_000},
                 "closing_held_cents" => 0
               },
               %{
                 "property_id" => "rtm-harbor",
                 "opening_held_cents" => 5_000,
                 "movements" => %{"charged_back_cents" => 5_000},
                 "closing_held_cents" => 0
               }
             ] = cash

      assert %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{"charged_back_cents" => 7_000}
                 },
                 %{
                   "property_id" => "rtm-harbor",
                   "movements" => %{"charged_back_cents" => 5_000}
                 }
               ]
             } = late
    end

    test "moves consumed credit into late adjustments", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-source"),
        open_operation("group-user",
          rate_plan: "advance_purchase",
          operation_id: "op-open-group-user"
        ),
        start_operation("op-start"),
        cash_operation("pay-source", "group-source", 8_000),
        cancel_operation("cancel-source", "group-source",
          refund_method: "hotel_credit",
          occurred_on: "2026-10-15"
        ),
        apply_credit_operation("apply-1", "group-user", 8_800)
      ])

      # The issued day is frozen with the close; consuming the credit with an
      # old-dated non-refundable cancellation committed afterwards can only
      # land on the first open day as a late adjustment.
      post_batch(conn, [close_operation("close-1")])

      issued_report = get_report!("2026-10-15")

      assert %{
               "status" => "closed",
               "late_adjustments" => %{"cash" => [], "credit" => issued_late}
             } =
               issued_report

      assert zero_credit_movements() == issued_late

      post_batch(build_conn(), [
        cancel_operation("cancel-user", "group-user", occurred_on: "2026-10-29")
      ])

      report = get_report!(@first_open_day)

      assert %{
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 8_800,
                 "movements" => credit_movements,
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => late
             } = report

      assert credit_movements(%{"consumed_cents" => 8_800}) == credit_movements

      # The late credit block is the movements object itself.
      refute Map.has_key?(late["credit"], "movements")
      assert credit_movements(%{"consumed_cents" => 8_800}) == late["credit"]
    end
  end
end
