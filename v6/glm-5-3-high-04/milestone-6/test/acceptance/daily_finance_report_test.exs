defmodule GroupStayWeb.DailyFinanceReportTest do
  @moduledoc """
  Acceptance tests for the daily finance report release: starting finance
  reporting, the opening position, per-property cash movements and
  company-wide credit movements, posting dates, and the read-only report
  endpoint.
  """

  use GroupStayWeb.ConnCase, async: false

  @batch_url "/api/v1/partner-batches"
  @report_url "/api/v1/finance/daily-report"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-open"),
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_500
      },
      overrides
    )
  end

  defp cancel_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-reduce"),
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-charge"),
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-1"
      },
      overrides
    )
  end

  defp transfer_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-transfer"),
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp start_reporting_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-start"),
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => "2026-11-01"
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  # group-82 is a one-room group of the same guest at syd-harbour whose
  # deposit is 60000.
  defp open_destination!(conn, overrides \\ %{}) do
    open_group!(
      conn,
      Map.merge(
        %{
          "group_id" => "group-82",
          "property_id" => "syd-harbour",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 100_000}]
        },
        overrides
      )
    )
  end

  defp daily_report!(conn, date) do
    conn = get(conn, @report_url <> "?date=" <> date)

    assert conn.status == 200,
           "expected 200 for #{date}, got: #{conn.status} #{inspect(json_response(conn, conn.status))}"

    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp cash_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "received_cents" => 0,
        "transferred_in_cents" => 0,
        "transferred_out_cents" => 0,
        "refunded_cents" => 0,
        "retained_cents" => 0,
        "converted_to_credit_cents" => 0,
        "reduced_cents" => 0,
        "charged_back_cents" => 0
      },
      overrides
    )
  end

  defp credit_movements(overrides \\ %{}) do
    Map.merge(
      %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      },
      overrides
    )
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => movements,
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => movements,
      "closing_liability_cents" => closing
    }
  end

  describe "starting finance reporting" do
    test "the first applied start returns exactly the three fields", %{conn: conn} do
      op = start_reporting_operation(%{"starts_on" => "2026-11-05"})

      result = apply_operation!(conn, op)

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "applied",
               "starts_on" => "2026-11-05"
             }
    end

    test "rejects an invalid or missing starts_on with invalid_reporting_date", %{conn: conn} do
      operations = [
        start_reporting_operation(%{"starts_on" => "2026-02-30"}),
        start_reporting_operation(%{"starts_on" => "not-a-date"}),
        start_reporting_operation(%{"starts_on" => "2026-11"}),
        start_reporting_operation(%{"starts_on" => 202_611}),
        start_reporting_operation(%{"starts_on" => nil}),
        Map.delete(start_reporting_operation(%{}), "starts_on")
      ]

      for operation <- operations do
        result = reject_operation!(conn, operation)
        assert result["code"] == "invalid_reporting_date", "for #{inspect(operation)}"
      end

      # A rejected start does not start reporting.
      apply_operation!(conn, start_reporting_operation(%{}))

      assert daily_report!(conn, "2026-11-01")["status"] == "open"
    end

    test "a different start is rejected once reporting has started", %{conn: conn} do
      first = start_reporting_operation(%{"operation_id" => "op-start-1"})
      apply_operation!(conn, first)

      result = reject_operation!(conn, start_reporting_operation(%{"starts_on" => "2026-12-01"}))
      assert result["code"] == "reporting_already_started"

      # A retry of the original operation replays its stored result.
      conn
      |> post_batch([first])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} ->
        assert retried == %{
                 "operation_id" => "op-start-1",
                 "status" => "applied",
                 "starts_on" => "2026-11-01"
               }
      end)

      # Reusing the identifier with a different payload is a conflict.
      result =
        reject_operation!(
          conn,
          start_reporting_operation(%{
            "operation_id" => "op-start-1",
            "starts_on" => "2026-12-01"
          })
        )

      assert result["code"] == "operation_id_conflict"
    end

    test "the opening position includes every committed operation", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 9_000,
          "occurred_on" => "2026-11-02"
        })
      )

      # The payment's occurred_on is starts_on itself, yet the payment is
      # part of the opening position, not a movement.
      apply_operation!(
        conn,
        start_reporting_operation(%{"occurred_on" => "2026-11-02", "starts_on" => "2026-11-02"})
      )

      report = daily_report!(conn, "2026-11-02")

      assert report["cash"] == [cash_entry("ams-canal", 9_000, cash_movements(), 9_000)]
      assert report["credit"] == credit_entry(0, credit_movements(), 0)

      report = daily_report!(conn, "2026-11-03")
      assert report["cash"] == [cash_entry("ams-canal", 9_000, cash_movements(), 9_000)]
    end

    test "operations before the start join the opening; after it, movements", %{conn: conn} do
      operations = [
        open_group_operation(%{}),
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "amount_cents" => 5_000,
          "occurred_on" => "2026-10-04"
        }),
        start_reporting_operation(%{"occurred_on" => "2026-10-05", "starts_on" => "2026-10-05"}),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "amount_cents" => 3_000,
          "occurred_on" => "2026-10-06"
        })
      ]

      conn
      |> post_batch(operations)
      |> json_response(200)
      |> then(fn %{"results" => results} ->
        assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]
      end)

      report = daily_report!(conn, "2026-10-05")
      assert report["cash"] == [cash_entry("ams-canal", 5_000, cash_movements(), 5_000)]

      report = daily_report!(conn, "2026-10-06")

      assert report["cash"] == [
               cash_entry("ams-canal", 5_000, cash_movements(%{"received_cents" => 3_000}), 8_000)
             ]
    end
  end

  describe "reading one day" do
    test "report errors before the start and for unusable dates", %{conn: conn} do
      conn = get(conn, @report_url <> "?date=2026-11-01")

      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = build_conn() |> get(@report_url)
      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = build_conn() |> get(@report_url <> "?date=2026-02-30")
      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      conn = build_conn() |> get(@report_url <> "?date=not-a-date")
      assert conn.status == 422
      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      apply_operation!(conn, start_reporting_operation(%{"starts_on" => "2026-11-05"}))

      conn = build_conn() |> get(@report_url <> "?date=2026-11-04")
      assert conn.status == 404
      assert json_response(conn, 404) == %{"error" => %{"code" => "report_not_available"}}

      conn = build_conn() |> get(@report_url <> "?date=2026-11-05")
      assert conn.status == 200
    end

    test "an empty report has no properties and zero credit", %{conn: conn} do
      apply_operation!(conn, start_reporting_operation(%{}))

      report = daily_report!(conn, "2026-11-01")

      assert report == %{
               "date" => "2026-11-01",
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(0, credit_movements(), 0)
             }
    end

    test "reports every cash classification across properties", %{conn: conn} do
      open_group!(conn)
      open_destination!(conn)

      apply_operation!(conn, start_reporting_operation(%{}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 9_000
        })
      )

      apply_operation!(
        conn,
        transfer_operation(%{"occurred_on" => "2026-11-03", "amount_cents" => 4_000})
      )

      # The transferred cash settles under the destination group's policy:
      # the refund is reported at syd-harbour, where the cash was held.
      apply_operation!(
        conn,
        cancel_group_operation(%{"group_id" => "group-82", "occurred_on" => "2026-11-04"})
      )

      apply_operation!(
        conn,
        reduce_operation(%{"occurred_on" => "2026-11-05", "amount_cents" => 2_000})
      )

      apply_operation!(
        conn,
        charge_back_operation(%{"occurred_on" => "2026-11-06"})
      )

      report = daily_report!(conn, "2026-11-02")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, cash_movements(%{"received_cents" => 9_000}), 9_000)
             ]

      # Transferred-in and transferred-out amounts are equal across
      # properties on the date.
      report = daily_report!(conn, "2026-11-03")

      assert report["cash"] == [
               cash_entry(
                 "ams-canal",
                 9_000,
                 cash_movements(%{"transferred_out_cents" => 4_000}),
                 5_000
               ),
               cash_entry(
                 "syd-harbour",
                 0,
                 cash_movements(%{"transferred_in_cents" => 4_000}),
                 4_000
               )
             ]

      report = daily_report!(conn, "2026-11-04")

      assert report["cash"] == [
               cash_entry("ams-canal", 5_000, cash_movements(), 5_000),
               cash_entry("syd-harbour", 4_000, cash_movements(%{"refunded_cents" => 4_000}), 0)
             ]

      # The correction follows the affected cash to the property where it
      # is held: ams-canal.
      report = daily_report!(conn, "2026-11-05")

      assert report["cash"] == [
               cash_entry("ams-canal", 5_000, cash_movements(%{"reduced_cents" => 2_000}), 3_000)
             ]

      # Reversing the earlier refund reports negative refunded cents
      # together with positive charged-back cents at the property where the
      # refund settled.
      report = daily_report!(conn, "2026-11-06")

      assert report["cash"] == [
               cash_entry(
                 "ams-canal",
                 3_000,
                 cash_movements(%{"charged_back_cents" => 3_000}),
                 0
               ),
               cash_entry(
                 "syd-harbour",
                 0,
                 cash_movements(%{"refunded_cents" => -4_000, "charged_back_cents" => 4_000}),
                 0
               )
             ]

      # The report reconciles with the current ledger views.
      current = ledger(conn)

      assert current["cash_held_cents"] == 0
      assert current["cash_refunded_cents"] == 0
      assert current["cash_reduced_cents"] == 2_000
      assert current["cash_charged_back_cents"] == 7_000
    end

    test "a reduction follows held cash across properties", %{conn: conn} do
      open_group!(conn)
      open_destination!(conn)

      apply_operation!(conn, start_reporting_operation(%{}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 9_000
        })
      )

      apply_operation!(
        conn,
        transfer_operation(%{"occurred_on" => "2026-11-03", "amount_cents" => 4_000})
      )

      # The reduction removes the most recent allocation first: the
      # transferred cash at syd-harbour, then the rest at ams-canal.
      apply_operation!(
        conn,
        reduce_operation(%{"occurred_on" => "2026-11-04", "amount_cents" => 6_000})
      )

      report = daily_report!(conn, "2026-11-04")

      assert report["cash"] == [
               cash_entry("ams-canal", 5_000, cash_movements(%{"reduced_cents" => 2_000}), 3_000),
               cash_entry("syd-harbour", 4_000, cash_movements(%{"reduced_cents" => 4_000}), 0)
             ]

      # The closing balances reconcile with the current ledger view.
      assert ledger(conn)["cash_held_cents"] == 3_000
    end

    test "non-refundable settlement retains cash at the property", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, start_reporting_operation(%{}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 9_000
        })
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"occurred_on" => "2026-12-01"})
      )

      report = daily_report!(conn, "2026-12-01")

      assert report["cash"] == [
               cash_entry("ams-canal", 9_000, cash_movements(%{"retained_cents" => 9_000}), 0)
             ]
    end
  end

  describe "credit movements" do
    test "issued, consumed, and revoked credit, and later expiry", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 5_000
        })
      )

      apply_operation!(
        conn,
        start_reporting_operation(%{"occurred_on" => "2026-11-02", "starts_on" => "2026-11-02"})
      )

      # Refundable cancellation settled as hotel credit: cash converts at
      # the property and a lot worth 110% is issued.
      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{
            "occurred_on" => "2026-11-03",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["credit_issued_cents"] == 5_500

      report = daily_report!(conn, "2026-11-03")

      assert report["cash"] == [
               cash_entry(
                 "ams-canal",
                 5_000,
                 cash_movements(%{"converted_to_credit_cents" => 5_000}),
                 0
               )
             ]

      assert report["credit"] ==
               credit_entry(0, credit_movements(%{"issued_cents" => 5_500}), 5_500)

      # Applying credit changes no liability and has no movement column.
      open_group!(
        conn,
        %{
          "group_id" => "group-84",
          "property_id" => "syd-harbour",
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 100_000}]
        }
      )

      apply_operation!(
        conn,
        apply_credit_operation(%{
          "group_id" => "group-84",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 2_000
        })
      )

      report = daily_report!(conn, "2026-11-04")
      assert report["credit"] == credit_entry(5_500, credit_movements(), 5_500)

      # Non-refundable settlement consumes applied credit.
      apply_operation!(
        conn,
        cancel_group_operation(%{"group_id" => "group-84", "occurred_on" => "2026-11-05"})
      )

      report = daily_report!(conn, "2026-11-05")

      assert report["credit"] ==
               credit_entry(5_500, credit_movements(%{"consumed_cents" => 2_000}), 3_500)

      # The report reconciles with the current credit-liability view.
      assert ledger(conn)["credit_liability_cents"] == 3_500

      # Unused credit expires on the day after its expires_on, even when no
      # partner operation was submitted that day. The lot was issued on
      # 2026-11-03 and expires on 2027-11-04.
      report = daily_report!(conn, "2027-11-04")
      assert report["credit"] == credit_entry(3_500, credit_movements(), 3_500)

      report = daily_report!(conn, "2027-11-05")

      assert report["credit"] ==
               credit_entry(3_500, credit_movements(%{"expired_cents" => 3_500}), 0)

      # Charging back the payment that funded the lot revokes the
      # entitlement value still held by the lot, and the earlier expiry
      # report changes with it.
      apply_operation!(
        conn,
        charge_back_operation(%{"occurred_on" => "2026-11-06"})
      )

      report = daily_report!(conn, "2026-11-06")

      assert report["credit"] ==
               credit_entry(3_500, credit_movements(%{"revoked_cents" => 3_500}), 0)

      assert report["cash"] == [
               cash_entry(
                 "ams-canal",
                 0,
                 cash_movements(%{
                   "converted_to_credit_cents" => -5_000,
                   "charged_back_cents" => 5_000
                 }),
                 0
               )
             ]

      report = daily_report!(conn, "2027-11-05")
      assert report["credit"] == credit_entry(0, credit_movements(), 0)
    end

    test "a chargeback with no recoverable entitlement reports no revocation", %{conn: conn} do
      # Issues a fully applied lot before reporting starts, then claws back
      # the entitlement while the credit funds an active group.
      open_group!(
        conn,
        %{
          "group_id" => "group-fund",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 100_000}]
        }
      )

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-fund",
          "group_id" => "group-fund",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 5_000
        })
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-fund",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      )

      apply_operation!(
        conn,
        start_reporting_operation(%{"occurred_on" => "2026-11-02", "starts_on" => "2026-11-02"})
      )

      # The pre-start lot is part of the opening liability.
      report = daily_report!(conn, "2026-11-02")
      assert report["credit"] == credit_entry(5_500, credit_movements(), 5_500)

      open_group!(conn, %{"group_id" => "group-85"})

      apply_operation!(
        conn,
        apply_credit_operation(%{
          "group_id" => "group-85",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 5_500
        })
      )

      report = daily_report!(conn, "2026-11-03")
      assert report["credit"] == credit_entry(5_500, credit_movements(), 5_500)

      # The lot's balance is fully applied, so the clawback cannot recover
      # anything: no revoked movement, the liability stays.
      apply_operation!(
        conn,
        charge_back_operation(%{
          "payment_operation_id" => "op-pay-fund",
          "occurred_on" => "2026-11-04"
        })
      )

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      report = daily_report!(conn, "2026-11-04")
      assert report["credit"] == credit_entry(5_500, credit_movements(), 5_500)

      # A refundable cancellation returns the credit to the shortfalled lot:
      # the restoration extinguishes the clawback through absorption.
      apply_operation!(
        conn,
        cancel_group_operation(%{"group_id" => "group-85", "occurred_on" => "2026-11-05"})
      )

      report = daily_report!(conn, "2026-11-05")

      assert report["credit"] ==
               credit_entry(5_500, credit_movements(%{"absorbed_cents" => 5_500}), 0)

      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "credit restored to an expired lot expires immediately", %{conn: conn} do
      open_group!(
        conn,
        %{
          "group_id" => "group-fund",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 100_000}]
        }
      )

      # A lot worth 1100 expiring on 2027-11-02.
      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-fund",
          "group_id" => "group-fund",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 1_000
        })
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{
          "group_id" => "group-fund",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        })
      )

      apply_operation!(
        conn,
        start_reporting_operation(%{"occurred_on" => "2026-11-02", "starts_on" => "2026-11-02"})
      )

      open_group!(
        conn,
        %{
          "group_id" => "group-far",
          "arrival_on" => "2029-01-01",
          "departure_on" => "2029-01-04",
          "rooms" => [%{"room_id" => "room-f", "nightly_rate_cents" => 100_000}]
        }
      )

      apply_operation!(
        conn,
        apply_credit_operation(%{
          "group_id" => "group-far",
          "occurred_on" => "2026-11-05",
          "amount_cents" => 1_100
        })
      )

      # Applied credit does not expire while it funds the group.
      report = daily_report!(conn, "2027-11-03")
      assert report["credit"] == credit_entry(1_100, credit_movements(), 1_100)

      # The refundable cancellation occurs after the lot's expiry, so the
      # restored amount expires immediately.
      apply_operation!(
        conn,
        cancel_group_operation(%{"group_id" => "group-far", "occurred_on" => "2028-01-01"})
      )

      report = daily_report!(conn, "2028-01-01")

      assert report["credit"] ==
               credit_entry(1_100, credit_movements(%{"expired_cents" => 1_100}), 0)
    end
  end

  describe "posting dates" do
    test "the posting date is the later of occurred_on and starts_on", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, start_reporting_operation(%{}))

      # A backdated payment posts on starts_on.
      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-10-15",
          "amount_cents" => 5_000
        })
      )

      report = daily_report!(conn, "2026-11-01")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, cash_movements(%{"received_cents" => 5_000}), 5_000)
             ]

      # A later submission changes the earlier open report.
      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 3_000
        })
      )

      report = daily_report!(conn, "2026-11-01")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, cash_movements(%{"received_cents" => 8_000}), 8_000)
             ]
    end
  end

  describe "durability" do
    test "rejected operations leave no movement and retries do not double", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, start_reporting_operation(%{}))

      batch = [
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 5_000
        }),
        payment_operation(%{
          "operation_id" => "op-pay-bad",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 999_999
        }),
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 2_000
        })
      ]

      conn
      |> post_batch(batch)
      |> json_response(200)
      |> then(fn %{"results" => results} ->
        assert Enum.map(results, & &1["status"]) == ["applied", "rejected", "applied"]
        assert Enum.at(results, 1)["code"] == "payment_exceeds_outstanding"
      end)

      report = daily_report!(conn, "2026-11-02")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, cash_movements(%{"received_cents" => 7_000}), 7_000)
             ]

      # A durable retry returns its stored result and does not report a
      # movement twice.
      conn
      |> post_batch([hd(batch)])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried["status"] == "applied" end)

      report = daily_report!(conn, "2026-11-02")

      assert report["cash"] == [
               cash_entry("ams-canal", 0, cash_movements(%{"received_cents" => 7_000}), 7_000)
             ]
    end

    test "reading reports never changes a report or domain state", %{conn: conn} do
      open_group!(conn)

      apply_operation!(conn, start_reporting_operation(%{}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 9_000
        })
      )

      before_group = fetch_group(conn, "group-81")
      before_ledger = ledger(conn)

      first = daily_report!(conn, "2026-11-02")
      daily_report!(conn, "2026-11-03")
      second = daily_report!(conn, "2026-11-02")

      assert first == second
      assert fetch_group(conn, "group-81") == before_group
      assert ledger(conn) == before_ledger
    end

    test "equivalent batches and sequential submissions produce equivalent reports", %{conn: conn} do
      # Two identical histories at two properties: one submitted as a
      # single batch, the other as sequential submissions.
      open_group!(conn, %{"group_id" => "group-batch", "property_id" => "prop-batch"})
      open_group!(conn, %{"group_id" => "group-seq", "property_id" => "prop-seq"})

      apply_operation!(conn, start_reporting_operation(%{}))

      conn
      |> post_batch([
        payment_operation(%{
          "operation_id" => "op-batch-1",
          "group_id" => "group-batch",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 4_000
        }),
        cancel_group_operation(%{
          "operation_id" => "op-batch-2",
          "group_id" => "group-batch",
          "occurred_on" => "2026-11-03"
        })
      ])
      |> json_response(200)
      |> then(fn %{"results" => results} ->
        assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
      end)

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-seq-1",
          "group_id" => "group-seq",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 4_000
        })
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{
          "operation_id" => "op-seq-2",
          "group_id" => "group-seq",
          "occurred_on" => "2026-11-03"
        })
      )

      report = daily_report!(conn, "2026-11-03")

      assert report["cash"] == [
               cash_entry("prop-batch", 4_000, cash_movements(%{"refunded_cents" => 4_000}), 0),
               cash_entry("prop-seq", 4_000, cash_movements(%{"refunded_cents" => 4_000}), 0)
             ]
    end
  end
end
