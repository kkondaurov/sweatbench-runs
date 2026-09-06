defmodule GroupStay.Acceptance.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  @open_occurred_on "2026-10-03"
  @arrival_on "2026-12-10"
  @departure_on "2026-12-13"
  @starts_on "2026-10-10"
  # Arrival minus the flex-14 window; cancelling on this date is refundable.
  @refundable_on "2026-11-26"
  # A lot issued on @refundable_on is available through 2027-11-26 and expires
  # on 2027-11-27.
  @lot_expires_on "2027-11-27"

  # Rooms a and b: lodgings 45_000 and 52_500; deposits 9_000 and 10_500.
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
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-04"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp apply_credit_operation(operation_id, group_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-12-01"),
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp cancel_operation(operation_id, group_id, opts \\ []) do
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
      "occurred_on" => "2026-10-12",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_operation(operation_id, payment_operation_id, amount_cents, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2026-10-14"),
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_operation(operation_id, payment_operation_id, opts \\ []) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => Keyword.get(opts, :occurred_on, "2027-02-01"),
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

  defp assert_report_unavailable(date) do
    assert %{"error" => %{"code" => "report_not_available"}} =
             build_conn()
             |> get("/api/v1/finance/daily-report?date=#{date}")
             |> json_response(404)
  end

  defp get_ledger!(date) do
    build_conn()
    |> get("/api/v1/ledger?on=#{date}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_guest_credit!(guest_id) do
    build_conn()
    |> get("/api/v1/guests/#{guest_id}/credit")
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

  describe "POST /api/v1/partner-batches with start_finance_reporting" do
    test "applies with exactly operation_id, status, and starts_on", %{conn: conn} do
      results = post_batch(conn, [start_operation("op-start")])

      assert [%{"operation_id" => "op-start", "status" => "applied", "starts_on" => @starts_on}] =
               results

      assert map_size(hd(results)) == 3
    end

    test "rejects a missing starts_on as invalid_reporting_date and allows a later start", %{
      conn: conn
    } do
      missing =
        start_operation("op-start")
        |> Map.delete("starts_on")

      assert [%{"status" => "rejected", "code" => "invalid_reporting_date"}] =
               post_batch(conn, [missing])

      assert [%{"status" => "applied"}] = post_batch(conn, [start_operation("op-start-2")])
    end

    test "rejects an unusable starts_on as invalid_reporting_date", %{conn: conn} do
      invalid =
        start_operation("op-start")
        |> Map.put("starts_on", "10/10/2026")

      assert [%{"status" => "rejected", "code" => "invalid_reporting_date"}] =
               post_batch(conn, [invalid])
    end

    test "an identical retry returns the stored result without starting again", %{conn: conn} do
      operation = start_operation("op-start")

      first = [%{"status" => "applied"}] = post_batch(conn, [operation])
      assert ^first = post_batch(conn, [operation])
      assert ^first = post_batch(conn, [operation])
    end

    test "reusing the identifier with a different payload is an operation_id_conflict", %{
      conn: conn
    } do
      assert [%{"status" => "applied"}] = post_batch(conn, [start_operation("op-start")])

      conflicting =
        start_operation("op-start")
        |> Map.put("starts_on", "2026-10-20")

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               post_batch(conn, [conflicting])

      # The original record stands: reports still start on the first date.
      assert_report_unavailable("2026-10-09")
      assert %{"date" => "2026-10-19"} = get_report!("2026-10-19")
    end

    test "a different start operation is rejected with reporting_already_started", %{conn: conn} do
      assert [%{"status" => "applied"}] = post_batch(conn, [start_operation("op-start")])

      assert [%{"status" => "rejected", "code" => "reporting_already_started"}] =
               post_batch(conn, [start_operation("op-start-2", "2026-11-01")])
    end
  end

  describe "GET /api/v1/finance/daily-report availability" do
    test "rejects a missing date as invalid_reporting_date", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_reporting_date"}} =
               conn |> get("/api/v1/finance/daily-report") |> json_response(422)
    end

    test "rejects an invalid date as invalid_reporting_date", %{conn: conn} do
      assert %{"error" => %{"code" => "invalid_reporting_date"}} =
               conn
               |> get("/api/v1/finance/daily-report?date=yesterday")
               |> json_response(422)
    end

    test "is unavailable before finance reporting has started", %{} do
      assert_report_unavailable(@starts_on)
    end

    test "is unavailable before starts_on once reporting has started", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      assert_report_unavailable("2026-10-09")

      assert %{"date" => @starts_on, "status" => "open"} = get_report!(@starts_on)
    end
  end

  describe "opening position and posting dates" do
    test "same-batch operations before the start open the position and later ones move it", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("group-81"),
        cash_operation("pay-1", "group-81", 5_000),
        start_operation("op-start"),
        cash_operation("pay-2", "group-81", 4_000, occurred_on: "2026-10-05"),
        cash_operation("pay-3", "group-81", 3_000, occurred_on: "2026-10-12")
      ])

      # pay-1 is part of the opening position everywhere; pay-2 posts on
      # starts_on (the later of its occurred_on and the start); pay-3 posts on
      # its own date.
      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "movements" => start_day_movements,
                 "closing_held_cents" => 9_000
               }
             ] = get_report!("2026-10-10")["cash"]

      assert cash_movements(%{"received_cents" => 4_000}) == start_day_movements

      assert [
               %{
                 "opening_held_cents" => 9_000,
                 "movements" => quiet_movements,
                 "closing_held_cents" => 9_000
               }
             ] = get_report!("2026-10-11")["cash"]

      assert zero_cash_movements() == quiet_movements

      assert [
               %{
                 "opening_held_cents" => 9_000,
                 "movements" => later_movements,
                 "closing_held_cents" => 12_000
               }
             ] = get_report!("2026-10-12")["cash"]

      assert cash_movements(%{"received_cents" => 3_000}) == later_movements
    end

    test "operations committed before the start stay in the opening even when dated after it", %{
      conn: conn
    } do
      post_batch(conn, [
        open_operation("group-81"),
        cash_operation("pay-late-dated", "group-81", 6_000, occurred_on: "2027-01-01")
      ])

      post_batch(conn, [start_operation("op-start")])

      assert [
               %{
                 "opening_held_cents" => 6_000,
                 "movements" => movements,
                 "closing_held_cents" => 6_000
               }
             ] = get_report!("2027-01-01")["cash"]

      assert zero_cash_movements() == movements
    end

    test "later submissions change an earlier open report", %{conn: conn} do
      post_batch(conn, [
        open_operation("group-81"),
        cash_operation("pay-1", "group-81", 5_000),
        start_operation("op-start"),
        cash_operation("pay-2", "group-81", 4_000, occurred_on: "2026-10-05")
      ])

      assert [%{"movements" => before, "closing_held_cents" => 9_000}] =
               get_report!("2026-10-10")["cash"]

      assert cash_movements(%{"received_cents" => 4_000}) == before

      post_batch(conn, [cash_operation("pay-3", "group-81", 2_000, occurred_on: "2026-10-08")])

      assert [%{"movements" => after_movements, "closing_held_cents" => 11_000}] =
               get_report!("2026-10-10")["cash"]

      assert cash_movements(%{"received_cents" => 6_000}) == after_movements
    end
  end

  describe "cash movements" do
    setup do
      operations = [
        open_operation("group-refund"),
        open_operation("group-retain",
          property_id: "rtm-harbor",
          rate_plan: "advance_purchase"
        ),
        open_operation("group-convert"),
        start_operation("op-start")
      ]

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied"
               }
             ] = post_batch(build_conn(), operations)

      payments = [
        cash_operation("pay-refund", "group-refund", 9_000, occurred_on: "2026-10-04"),
        cash_operation("pay-retain", "group-retain", 1_000, occurred_on: "2026-10-05"),
        cash_operation("pay-convert", "group-convert", 8_000, occurred_on: "2026-10-06")
      ]

      assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
               post_batch(build_conn(), payments)

      settlements = [
        cancel_operation("cancel-refund", "group-refund", refund_method: "cash"),
        cancel_operation("cancel-retain", "group-retain"),
        cancel_operation("cancel-convert", "group-convert", refund_method: "hotel_credit")
      ]

      assert [
               %{"refunded_cents" => 9_000, "retained_cents" => 0, "credit_issued_cents" => 0},
               %{"refunded_cents" => 0, "retained_cents" => 1_000, "credit_issued_cents" => 0},
               %{"refunded_cents" => 0, "retained_cents" => 0, "credit_issued_cents" => 8_800}
             ] = post_batch(build_conn(), settlements)

      :ok
    end

    test "reports receipts on their posting dates ordered by property" do
      report = get_report!("2026-10-10")

      assert %{
               "date" => "2026-10-10",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{"received_cents" => 17_000},
                   "closing_held_cents" => 17_000
                 },
                 %{
                   "property_id" => "rtm-harbor",
                   "opening_held_cents" => 0,
                   "movements" => %{"received_cents" => 1_000},
                   "closing_held_cents" => 1_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => quiet_credit,
                 "closing_liability_cents" => 0
               }
             } = report

      assert zero_credit_movements() == quiet_credit
    end

    test "reports refunds, retentions, and conversions at the settling property" do
      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 17_000,
                 "movements" => ams_movements,
                 "closing_held_cents" => 0
               },
               %{
                 "property_id" => "rtm-harbor",
                 "opening_held_cents" => 1_000,
                 "movements" => rtm_movements,
                 "closing_held_cents" => 0
               }
             ] = get_report!(@refundable_on)["cash"]

      assert cash_movements(%{
               "refunded_cents" => 9_000,
               "converted_to_credit_cents" => 8_000
             }) == ams_movements

      assert cash_movements(%{"retained_cents" => 1_000}) == rtm_movements

      assert %{
               "opening_liability_cents" => 0,
               "movements" => issued_movements,
               "closing_liability_cents" => 8_800
             } = get_report!(@refundable_on)["credit"]

      assert credit_movements(%{"issued_cents" => 8_800}) == issued_movements
    end

    test "omits properties with nothing to show but keeps those that only moved" do
      # Between the receipts and the settlements both properties still hold
      # cash even though nothing moves on the date itself.
      assert [
               %{"property_id" => "ams-canal", "opening_held_cents" => 17_000},
               %{"property_id" => "rtm-harbor", "opening_held_cents" => 1_000}
             ] =
               get_report!("2026-11-01")["cash"]
               |> Enum.map(&Map.take(&1, ["property_id", "opening_held_cents"]))

      # Once every balance and movement of a date nets to zero, the property
      # is omitted entirely.
      assert [] = get_report!("2027-06-01")["cash"]
    end
  end

  describe "chargebacks" do
    test "reversing a settled refund shows negative refunded with positive charged_back" do
      post_batch(build_conn(), [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      post_batch(build_conn(), [cash_operation("pay-1", "group-81", 9_000)])

      post_batch(build_conn(), [
        cancel_operation("cancel-1", "group-81", refund_method: "cash")
      ])

      post_batch(build_conn(), [charge_back_operation("chb-1", "pay-1")])

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => reversal_movements,
                 "closing_held_cents" => 0
               }
             ] = get_report!("2027-02-01")["cash"]

      assert cash_movements(%{"refunded_cents" => -9_000, "charged_back_cents" => 9_000}) ==
               reversal_movements

      assert %{"cash_held_cents" => 0} = get_ledger!("2027-02-01")
    end

    test "follows held cash to the properties where it currently funds rooms" do
      post_batch(build_conn(), [
        open_operation("group-src"),
        open_operation("group-dst", property_id: "rtm-harbor"),
        start_operation("op-start")
      ])

      post_batch(build_conn(), [cash_operation("pay-1", "group-src", 12_000)])

      post_batch(build_conn(), [
        transfer_operation("transfer-1", "group-src", "group-dst", 5_000)
      ])

      post_batch(build_conn(), [
        charge_back_operation("chb-1", "pay-1", occurred_on: "2026-10-16")
      ])

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
             ] = get_report!("2026-10-16")["cash"]
    end

    test "settled portions that predate reporting produce no reclassification movement" do
      # pay-1 is fully refunded before finance reporting starts.
      post_batch(build_conn(), [
        open_operation("group-81"),
        cash_operation("pay-1", "group-81", 9_000),
        cancel_operation("cancel-1", "group-81", refund_method: "cash"),
        start_operation("op-start")
      ])

      post_batch(build_conn(), [
        charge_back_operation("chb-1", "pay-1", occurred_on: "2026-11-01")
      ])

      # The refund never appeared as a reporting movement - it is part of no
      # opening balance - so reversing it must not move any report either,
      # even though the ledger records the reclassification.
      report = get_report!("2026-11-01")

      assert [] = report["cash"]
      assert zero_credit_movements() == report["credit"]["movements"]

      statement =
        build_conn()
        |> get("/api/v1/payments/pay-1")
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"held_cents" => 0, "refunded_cents" => 0, "charged_back_cents" => 9_000} =
               statement
    end
  end

  describe "transfers and reductions" do
    test "books transfers on both properties and follows reductions to where cash is held" do
      post_batch(build_conn(), [
        open_operation("group-src"),
        open_operation("group-dst", property_id: "rtm-harbor"),
        start_operation("op-start")
      ])

      post_batch(build_conn(), [cash_operation("pay-1", "group-src", 12_000)])

      post_batch(build_conn(), [
        transfer_operation("transfer-1", "group-src", "group-dst", 5_000)
      ])

      post_batch(build_conn(), [reduce_operation("reduce-1", "pay-1", 3_000)])

      transfer_report = get_report!("2026-10-12")["cash"]

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 12_000,
                 "movements" => %{"transferred_out_cents" => 5_000},
                 "closing_held_cents" => 7_000
               },
               %{
                 "property_id" => "rtm-harbor",
                 "opening_held_cents" => 0,
                 "movements" => %{"transferred_in_cents" => 5_000},
                 "closing_held_cents" => 5_000
               }
             ] = transfer_report

      # Transfers in equal transfers out across all properties on the date.
      net_transfers =
        Enum.reduce(transfer_report, 0, fn entry, sum ->
          sum + entry["movements"]["transferred_in_cents"] -
            entry["movements"]["transferred_out_cents"]
        end)

      assert net_transfers == 0

      # The reduction follows the transferred cash to rtm-harbor, where the
      # most recently created allocations now fund rooms.
      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 7_000,
                 "movements" => quiet_a,
                 "closing_held_cents" => 7_000
               },
               %{
                 "property_id" => "rtm-harbor",
                 "opening_held_cents" => 5_000,
                 "movements" => %{"reduced_cents" => 3_000},
                 "closing_held_cents" => 2_000
               }
             ] = get_report!("2026-10-14")["cash"]

      assert zero_cash_movements() == quiet_a
    end
  end

  describe "credit liability movements" do
    setup do
      post_batch(build_conn(), [
        open_operation("group-source"),
        start_operation("op-start")
      ])

      post_batch(build_conn(), [cash_operation("pay-source", "group-source", 8_000)])

      post_batch(build_conn(), [
        cancel_operation("cancel-source", "group-source", refund_method: "hotel_credit")
      ])

      :ok
    end

    test "shows expiry of unused credit on its expiry date without any operation" do
      assert %{
               "opening_liability_cents" => 0,
               "movements" => issued_movements,
               "closing_liability_cents" => 8_800
             } = get_report!(@refundable_on)["credit"]

      assert credit_movements(%{"issued_cents" => 8_800}) == issued_movements

      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => mid_life_movements,
               "closing_liability_cents" => 8_800
             } = get_report!("2027-06-01")["credit"]

      assert zero_credit_movements() == mid_life_movements

      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => expiry_movements,
               "closing_liability_cents" => 0
             } = get_report!(@lot_expires_on)["credit"]

      assert credit_movements(%{"expired_cents" => 8_800}) == expiry_movements

      assert %{
               "opening_liability_cents" => 0,
               "movements" => after_expiry_movements,
               "closing_liability_cents" => 0
             } = get_report!("2027-11-28")["credit"]

      assert zero_credit_movements() == after_expiry_movements

      # Reports reconcile with the ledger read for the same date.
      assert %{"credit_liability_cents" => 0} = get_ledger!(@lot_expires_on)
    end

    test "consumed credit leaves liability through non-refundable settlement" do
      post_batch(build_conn(), [
        open_operation("group-user",
          rate_plan: "advance_purchase",
          operation_id: "op-open-group-user"
        ),
        apply_credit_operation("apply-1", "group-user", 5_000)
      ])

      post_batch(build_conn(), [
        cancel_operation("cancel-user", "group-user", occurred_on: "2026-12-03")
      ])

      # Applying credit itself never moves liability.
      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => apply_day_movements,
               "closing_liability_cents" => 8_800
             } = get_report!("2026-12-01")["credit"]

      assert zero_credit_movements() == apply_day_movements

      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => consumed_movements,
               "closing_liability_cents" => 3_800
             } = get_report!("2026-12-03")["credit"]

      assert credit_movements(%{"consumed_cents" => 5_000}) == consumed_movements

      # The remaining 3_800 still expires on the lot's expiry date.
      assert %{"movements" => %{"expired_cents" => 3_800}, "closing_liability_cents" => 0} =
               get_report!(@lot_expires_on)["credit"]
    end

    test "revoked entitlements leave liability when converted cash is charged back" do
      assert [%{"status" => "applied", "charged_back_cents" => 8_000}] =
               post_batch(build_conn(), [
                 charge_back_operation("chb-1", "pay-source", occurred_on: "2027-01-15")
               ])

      report = get_report!("2027-01-15")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => reversal,
                 "closing_held_cents" => 0
               }
             ] = report["cash"]

      assert cash_movements(%{
               "converted_to_credit_cents" => -8_000,
               "charged_back_cents" => 8_000
             }) == reversal

      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => revoked_movements,
               "closing_liability_cents" => 0
             } = report["credit"]

      assert credit_movements(%{"revoked_cents" => 8_800}) == revoked_movements

      assert %{"available_cents" => 0, "lots" => []} = get_guest_credit!("guest-22")
    end

    test "absorbed restorations reduce liability at shortfalled lots" do
      # A stay far enough out that cancelling on 2027-01-10 is still
      # refundable under the flex-14 policy fixed at booking.
      post_batch(build_conn(), [
        open_operation("group-user",
          operation_id: "op-open-group-user",
          arrival_on: "2027-02-10",
          departure_on: "2027-02-13"
        )
      ])

      post_batch(build_conn(), [apply_credit_operation("apply-1", "group-user", 8_800)])

      # Charging back the converted payment claws back an entitlement whose
      # whole balance is applied to group-user, so nothing is recovered yet
      # and no liability moves.
      post_batch(build_conn(), [
        charge_back_operation("chb-1", "pay-source", occurred_on: "2026-12-20")
      ])

      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => clawback_day_movements,
               "closing_liability_cents" => 8_800
             } = get_report!("2026-12-20")["credit"]

      assert zero_credit_movements() == clawback_day_movements

      assert %{"credit_liability_cents" => 8_800, "credit_shortfall_cents" => 8_800} =
               get_ledger!("2026-12-31")

      # Refundable settlement restores the applied credit, which the
      # shortfalled lot absorbs in full.
      post_batch(build_conn(), [
        cancel_operation("cancel-user", "group-user", occurred_on: "2027-01-10")
      ])

      assert %{
               "opening_liability_cents" => 8_800,
               "movements" => absorbed_movements,
               "closing_liability_cents" => 0
             } = get_report!("2027-01-10")["credit"]

      assert credit_movements(%{"absorbed_cents" => 8_800}) == absorbed_movements

      assert %{"credit_shortfall_cents" => 0} = get_ledger!("2027-01-10")
    end
  end

  describe "report consistency" do
    test "reconciles closing balances with the ledger reads" do
      post_batch(build_conn(), [
        open_operation("group-a"),
        open_operation("group-b", property_id: "rtm-harbor", rate_plan: "advance_purchase"),
        start_operation("op-start")
      ])

      post_batch(build_conn(), [
        cash_operation("pay-a", "group-a", 12_000, occurred_on: "2026-10-04"),
        cash_operation("pay-b", "group-b", 4_000, occurred_on: "2026-10-05")
      ])

      post_batch(build_conn(), [
        transfer_operation("transfer-1", "group-a", "group-b", 3_000)
      ])

      post_batch(build_conn(), [
        reduce_operation("reduce-1", "pay-a", 2_000, occurred_on: "2026-10-16")
      ])

      polarities = %{
        "received_cents" => 1,
        "transferred_in_cents" => 1,
        "transferred_out_cents" => -1,
        "refunded_cents" => -1,
        "retained_cents" => -1,
        "converted_to_credit_cents" => -1,
        "reduced_cents" => -1,
        "charged_back_cents" => -1
      }

      for date <- ["2026-10-10", "2026-10-12", "2026-10-16", "2027-08-01"] do
        report = get_report!(date)
        ledger = get_ledger!(date)

        # Every property's report closes with the documented identity.
        Enum.each(report["cash"], fn entry ->
          delta =
            entry["movements"]
            |> Enum.map(fn {kind, amount} -> amount * Map.fetch!(polarities, kind) end)
            |> Enum.sum()

          assert entry["closing_held_cents"] == entry["opening_held_cents"] + delta,
                 "cash identity breaks on #{date} for #{entry["property_id"]}"
        end)

        credit_delta =
          report["credit"]["movements"]
          |> Map.delete("issued_cents")
          |> Enum.map(fn {_, amount} -> -amount end)
          |> Enum.sum()
          |> Kernel.+(report["credit"]["movements"]["issued_cents"])

        assert report["credit"]["closing_liability_cents"] ==
                 report["credit"]["opening_liability_cents"] + credit_delta

        # Once every submitted movement has posted, the closing balances are
        # the current views.
        if date in ["2026-10-16", "2027-08-01"] do
          held = report["cash"] |> Enum.map(& &1["closing_held_cents"]) |> Enum.sum()

          assert held == ledger["cash_held_cents"], "held cash diverges on #{date}"

          assert report["credit"]["closing_liability_cents"] ==
                   ledger["credit_liability_cents"],
                 "credit liability diverges on #{date}"
        end
      end
    end

    test "reading reports repeatedly never changes them" do
      post_batch(build_conn(), [
        open_operation("group-81"),
        cash_operation("pay-1", "group-81", 5_000),
        start_operation("op-start")
      ])

      first = get_report!(@starts_on)
      second = get_report!(@starts_on)
      third = get_report!("2027-08-01")

      assert first == second
      assert third == get_report!("2027-08-01")
      assert first == get_report!(@starts_on)
    end

    test "retries do not report movements twice and rejections leave no movement" do
      post_batch(build_conn(), [
        open_operation("group-81"),
        start_operation("op-start")
      ])

      batch = [
        cash_operation("pay-1", "group-81", 5_000),
        cash_operation("pay-too-much", "group-81", 999_999)
      ]

      first_results = post_batch(build_conn(), batch)

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = first_results

      assert ^first_results = post_batch(build_conn(), batch)

      assert [%{"movements" => movements, "closing_held_cents" => 5_000}] =
               get_report!(@starts_on)["cash"]

      assert cash_movements(%{"received_cents" => 5_000}) == movements

      # Movements from earlier operations survive a later rejection in the
      # same batch.
      post_batch(build_conn(), [
        cash_operation("pay-2", "group-81", 2_000),
        cash_operation("pay-also-too-much", "group-81", 999_999)
      ])

      assert [%{"movements" => movements_after, "closing_held_cents" => 7_000}] =
               get_report!(@starts_on)["cash"]

      assert cash_movements(%{"received_cents" => 7_000}) == movements_after
    end
  end
end
