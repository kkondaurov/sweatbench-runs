defmodule GroupStayWeb.PeriodCloseTest do
  @moduledoc """
  Acceptance tests for the finance period close release: the
  `close_finance_period` operation and its durable replay, published and
  byte-for-byte stable closed reports, posting dates after a close, and the
  late-adjustments block of the daily finance report.
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
        "occurred_on" => "2026-11-02",
        "group_id" => "group-81",
        "amount_cents" => 100
      },
      overrides
    )
  end

  defp cancel_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-03",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-charge"),
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-04",
        "payment_operation_id" => "op-pay-1"
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

  defp close_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-close"),
        "type" => "close_finance_period",
        "occurred_on" => "2026-11-05",
        "period_end_on" => "2026-11-05"
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

  # A one-room group of the same guest at another property.
  defp open_group_at!(conn, group_id, property_id) do
    open_group!(
      conn,
      %{
        "group_id" => group_id,
        "property_id" => property_id,
        "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 100_000}]
      }
    )
  end

  # The standard history: reporting starts on 2026-11-01 with group-81
  # funded by one 100-cent payment posted on 2026-11-02.
  defp started_history!(conn, payment_overrides \\ %{}) do
    open_group!(conn)

    apply_operation!(
      conn,
      payment_operation(Map.merge(%{"operation_id" => "op-pay-1"}, payment_overrides))
    )

    apply_operation!(conn, start_reporting_operation(%{}))
  end

  defp daily_report!(conn, date) do
    conn = get(conn, @report_url <> "?date=" <> date)

    assert conn.status == 200,
           "expected 200 for #{date}, got: #{conn.status} #{inspect(json_response(conn, conn.status))}"

    %{"data" => data} = json_response(conn, 200)
    data
  end

  # The exact response body of one report read.
  defp report_body!(conn, date) do
    conn = get(conn, @report_url <> "?date=" <> date)
    assert conn.status == 200
    conn.resp_body
  end

  defp payment_statement(conn, payment_operation_id) do
    conn = get(conn, "/api/v1/payments/" <> payment_operation_id)
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

  defp late_cash_entry(property_id, movements) do
    %{"property_id" => property_id, "movements" => movements}
  end

  describe "the close operation" do
    test "an applied close returns exactly the three fields", %{conn: conn} do
      started_history!(conn)

      op = close_operation(%{"period_end_on" => "2026-11-05"})

      result = apply_operation!(conn, op)

      assert result == %{
               "operation_id" => op["operation_id"],
               "status" => "applied",
               "period_end_on" => "2026-11-05"
             }
    end

    test "rejects a close before reporting has started", %{conn: conn} do
      open_group!(conn)

      operations = [
        close_operation(%{}),
        close_operation(%{"period_end_on" => "2026-11-05"})
      ]

      for operation <- operations do
        result = reject_operation!(conn, operation)
        assert result["code"] == "invalid_period", "for #{inspect(operation)}"
      end

      # Reporting can still start afterwards, and the close then applies.
      apply_operation!(conn, start_reporting_operation(%{}))
      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))
      assert daily_report!(conn, "2026-11-05")["status"] == "closed"
    end

    test "rejects a period_end_on before starts_on", %{conn: conn} do
      started_history!(conn)

      result = reject_operation!(conn, close_operation(%{"period_end_on" => "2026-10-31"}))
      assert result["code"] == "invalid_period"

      # starts_on itself is on or after starts_on.
      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-01"}))
      assert daily_report!(conn, "2026-11-01")["status"] == "closed"
    end

    test "rejects the same or an earlier cutoff than the latest close", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      for period_end_on <- ["2026-11-05", "2026-11-04", "2026-11-01"] do
        result = reject_operation!(conn, close_operation(%{"period_end_on" => period_end_on}))
        assert result["code"] == "invalid_period", "for #{period_end_on}"
      end

      # A strictly later close still applies.
      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-06"}))
      assert daily_report!(conn, "2026-11-06")["status"] == "closed"
      assert daily_report!(conn, "2026-11-07")["status"] == "open"
    end

    test "rejects an invalid or missing period_end_on", %{conn: conn} do
      started_history!(conn)

      operations = [
        close_operation(%{"period_end_on" => "2026-02-30"}),
        close_operation(%{"period_end_on" => "not-a-date"}),
        close_operation(%{"period_end_on" => "2026-11"}),
        close_operation(%{"period_end_on" => 202_611}),
        close_operation(%{"period_end_on" => nil}),
        Map.delete(close_operation(%{}), "period_end_on")
      ]

      for operation <- operations do
        result = reject_operation!(conn, operation)
        assert result["code"] == "invalid_period", "for #{inspect(operation)}"
      end

      # No close happened: every report is still open.
      assert daily_report!(conn, "2026-11-30")["status"] == "open"
    end

    test "does not address a group and has no revision guard", %{conn: conn} do
      started_history!(conn)

      # Group fields on the payload are inert: no group is resolved and no
      # revision is checked, even a nonsense one.
      result =
        apply_operation!(
          conn,
          close_operation(%{
            "group_id" => "group-81",
            "expected_revision" => 999
          })
        )

      assert result["status"] == "applied"

      # The group's own revision is untouched.
      conn = get(conn, "/api/v1/groups/group-81")
      %{"data" => group} = json_response(conn, 200)
      assert group["revision"] == 2
    end

    test "replays the stored result and rejects a conflicting reuse", %{conn: conn} do
      started_history!(conn)

      close = close_operation(%{"operation_id" => "op-close-1", "period_end_on" => "2026-11-05"})
      apply_operation!(conn, close)

      conn
      |> post_batch([close])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} ->
        assert retried == %{
                 "operation_id" => "op-close-1",
                 "status" => "applied",
                 "period_end_on" => "2026-11-05"
               }
      end)

      result =
        reject_operation!(
          conn,
          close_operation(%{
            "operation_id" => "op-close-1",
            "period_end_on" => "2026-11-06"
          })
        )

      assert result["code"] == "operation_id_conflict"
    end

    test "a rejected close does not publish anything", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # A rejected later cutoff leaves the published range unchanged.
      reject_operation!(conn, close_operation(%{"period_end_on" => "2026-11-04"}))

      assert daily_report!(conn, "2026-11-05")["status"] == "closed"
      assert daily_report!(conn, "2026-11-06")["status"] == "open"
    end
  end

  describe "published reports" do
    test "reports through the cutoff are closed and later reports are open", %{conn: conn} do
      started_history!(conn)

      assert daily_report!(conn, "2026-11-02")["status"] == "open"

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      assert daily_report!(conn, "2026-11-01")["status"] == "closed"
      assert daily_report!(conn, "2026-11-05")["status"] == "closed"
      assert daily_report!(conn, "2026-11-06")["status"] == "open"

      # A later close extends the closed range.
      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-20"}))

      assert daily_report!(conn, "2026-11-20")["status"] == "closed"
      assert daily_report!(conn, "2026-11-21")["status"] == "open"
    end

    test "closed reports stay byte-for-byte stable across later operations", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      frozen_body = report_body!(conn, "2026-11-02")
      frozen = daily_report!(conn, "2026-11-02")

      # Old-dated operations after the close cannot touch the closed day.
      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-late",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 5_000
        })
      )

      apply_operation!(
        conn,
        cancel_group_operation(%{"occurred_on" => "2026-11-03"})
      )

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-10"}))

      assert report_body!(conn, "2026-11-02") == frozen_body
      assert daily_report!(conn, "2026-11-02") == frozen

      # The late effects are visible only on the first open day: the
      # old-dated payment posts its whole 5,000 there, and the old-dated
      # cancellation refunds everything then held — all 5,100 — there too.
      report = daily_report!(conn, "2026-11-06")

      assert report["cash"] == [cash_entry("ams-canal", 100, cash_movements(), 0)]

      assert report["late_adjustments"]["cash"] == [
               late_cash_entry(
                 "ams-canal",
                 cash_movements(%{"received_cents" => 5_000, "refunded_cents" => 5_100})
               )
             ]
    end

    test "a close publishes the reports as they stand, including in-batch operations", %{
      conn: conn
    } do
      started_history!(conn)

      # The payment immediately before the close posts into the closing
      # period and is frozen into its report.
      conn
      |> post_batch([
        payment_operation(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-11-04",
          "amount_cents" => 200
        }),
        close_operation(%{"period_end_on" => "2026-11-05"})
      ])
      |> json_response(200)
      |> then(fn %{"results" => results} ->
        assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
      end)

      report = daily_report!(conn, "2026-11-04")

      assert report["status"] == "closed"

      assert report["cash"] == [
               cash_entry("ams-canal", 100, cash_movements(%{"received_cents" => 200}), 300)
             ]
    end

    test "a later close freezes the open reports without moving them", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # An old-dated operation posts on the first open day, 2026-11-06.
      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-late",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 5_000
        })
      )

      open_report = daily_report!(conn, "2026-11-06")
      assert open_report["status"] == "open"

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-10"}))

      frozen = daily_report!(conn, "2026-11-06")

      assert frozen["status"] == "closed"
      assert Map.delete(frozen, "status") == Map.delete(open_report, "status")
    end

    test "reading closed reports never changes state", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      before_group_conn = get(conn, "/api/v1/groups/group-81")
      before_group = json_response(before_group_conn, 200)
      before_ledger = ledger(conn)

      first = daily_report!(conn, "2026-11-02")
      daily_report!(conn, "2026-11-03")
      second = daily_report!(conn, "2026-11-02")

      assert first == second

      after_group_conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(after_group_conn, 200) == before_group
      assert ledger(conn) == before_ledger
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts its whole effect on the first open day", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # The old-dated refund posts on 2026-11-06: cash leaves ams-canal and
      # credit is issued, all as late adjustments of that one day.
      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{
            "occurred_on" => "2026-11-03",
            "refund_method" => "hotel_credit"
          })
        )

      assert result["credit_issued_cents"] == 110

      report = daily_report!(conn, "2026-11-06")

      assert report["cash"] == [cash_entry("ams-canal", 100, cash_movements(), 0)]

      assert report["credit"] == credit_entry(0, credit_movements(), 110)

      assert report["late_adjustments"] == %{
               "cash" => [
                 late_cash_entry(
                   "ams-canal",
                   cash_movements(%{"converted_to_credit_cents" => 100})
                 )
               ],
               "credit" => credit_movements(%{"issued_cents" => 110})
             }
    end

    test "an operation in the open period keeps its occurred_on", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-open",
          "occurred_on" => "2026-11-10",
          "amount_cents" => 5_000
        })
      )

      report = daily_report!(conn, "2026-11-10")

      assert report["status"] == "open"

      assert report["cash"] == [
               cash_entry("ams-canal", 100, cash_movements(%{"received_cents" => 5_000}), 5_100)
             ]

      assert report["late_adjustments"] == %{"cash" => [], "credit" => credit_movements()}
    end

    test "an operation dated on the first open day posts on it as ordinary", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-open",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        })
      )

      report = daily_report!(conn, "2026-11-06")

      assert report["cash"] == [
               cash_entry("ams-canal", 100, cash_movements(%{"received_cents" => 5_000}), 5_100)
             ]

      assert report["late_adjustments"] == %{"cash" => [], "credit" => credit_movements()}
    end

    test "an old-dated operation immediately after a close posts on the first open day", %{
      conn: conn
    } do
      started_history!(conn)

      conn
      |> post_batch([
        close_operation(%{"period_end_on" => "2026-11-05"}),
        payment_operation(%{
          "operation_id" => "op-pay-old",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 5_000
        })
      ])
      |> json_response(200)
      |> then(fn %{"results" => results} ->
        assert Enum.map(results, & &1["status"]) == ["applied", "applied"]
      end)

      # The closed day was published before the payment committed; the
      # opening payment is part of the opening position, not a movement.
      report = daily_report!(conn, "2026-11-02")

      assert report["status"] == "closed"
      assert report["cash"] == [cash_entry("ams-canal", 100, cash_movements(), 100)]

      report = daily_report!(conn, "2026-11-06")

      assert report["cash"] == [cash_entry("ams-canal", 100, cash_movements(), 5_100)]

      assert report["late_adjustments"]["cash"] == [
               late_cash_entry("ams-canal", cash_movements(%{"received_cents" => 5_000}))
             ]
    end

    test "reporting-domain reads keep their current-state meanings", %{conn: conn} do
      started_history!(conn)

      apply_operation!(
        conn,
        cancel_group_operation(%{"occurred_on" => "2026-11-03"})
      )

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # An old-dated chargeback posts on the first open day, but the stored
      # operation result, the payment statement, and the ledger still report
      # current state.
      result =
        apply_operation!(
          conn,
          charge_back_operation(%{"occurred_on" => "2026-11-04"})
        )

      assert result["charged_back_cents"] == 100

      statement = payment_statement(conn, "op-pay-1")
      assert statement["charged_back_cents"] == 100
      assert statement["refunded_cents"] == 0

      current = ledger(conn)
      assert current["cash_refunded_cents"] == 0
      assert current["cash_charged_back_cents"] == 100
    end
  end

  describe "identifying late adjustments" do
    test "every report carries the block, empty without a close", %{conn: conn} do
      started_history!(conn)

      report = daily_report!(conn, "2026-11-02")

      assert report["late_adjustments"] == %{"cash" => [], "credit" => credit_movements()}
    end

    test "a zero-net reversal keeps its signed classifications", %{conn: conn} do
      started_history!(conn)

      # The refund happens inside the period being closed.
      apply_operation!(
        conn,
        cancel_group_operation(%{"occurred_on" => "2026-11-03"})
      )

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # The chargeback is dated inside the closed period and posts on the
      # first open day: it reverses the refunded 100 cents.
      apply_operation!(
        conn,
        charge_back_operation(%{"occurred_on" => "2026-11-04"})
      )

      report = daily_report!(conn, "2026-11-06")

      # The property has zero balances and no ordinary movement, so it has
      # no ordinary cash entry — but the adjustment does not disappear.
      assert report["cash"] == []

      assert report["late_adjustments"]["cash"] == [
               late_cash_entry(
                 "ams-canal",
                 cash_movements(%{"refunded_cents" => -100, "charged_back_cents" => 100})
               )
             ]

      assert report["late_adjustments"]["credit"] == credit_movements()
    end

    test "late cash entries are ordered by property_id and omit other properties", %{conn: conn} do
      open_group!(conn)
      open_group_at!(conn, "group-82", "syd-harbour")
      open_group_at!(conn, "group-83", "lon-eyrie")

      apply_operation!(conn, start_reporting_operation(%{}))

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # Two old-dated payments post late at two properties...
      conn
      |> post_batch([
        payment_operation(%{
          "operation_id" => "op-pay-old-1",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 100
        }),
        payment_operation(%{
          "operation_id" => "op-pay-old-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 200
        })
      ])
      |> json_response(200)

      # ...and one in-period payment posts ordinarily at a third.
      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-now",
          "group_id" => "group-83",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 300
        })
      )

      report = daily_report!(conn, "2026-11-06")

      assert report["late_adjustments"]["cash"] == [
               late_cash_entry("ams-canal", cash_movements(%{"received_cents" => 100})),
               late_cash_entry("syd-harbour", cash_movements(%{"received_cents" => 200}))
             ]

      # The ordinary cash entries carry the balances of every property and
      # the ordinary movement of the day; only lon-eyrie has one.
      assert report["cash"] == [
               cash_entry("ams-canal", 0, cash_movements(), 100),
               cash_entry("lon-eyrie", 0, cash_movements(%{"received_cents" => 300}), 300),
               cash_entry("syd-harbour", 0, cash_movements(), 200)
             ]
    end

    test "a late revocation of an unexpired lot reports in the credit block", %{conn: conn} do
      started_history!(conn)

      # Refundable cancellation settled as hotel credit: the lot is issued
      # on 2026-11-03 and expires on 2027-12-03.
      apply_operation!(
        conn,
        cancel_group_operation(%{
          "occurred_on" => "2026-11-03",
          "refund_method" => "hotel_credit"
        })
      )

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      # The old-dated chargeback posts on the first open day: it reverses
      # the conversion and revokes the entitlement value still held by the
      # unexpired lot.
      apply_operation!(
        conn,
        charge_back_operation(%{"occurred_on" => "2026-11-04"})
      )

      report = daily_report!(conn, "2026-11-06")

      assert report["cash"] == []

      assert report["credit"] == credit_entry(110, credit_movements(), 0)

      assert report["late_adjustments"] == %{
               "cash" => [
                 late_cash_entry(
                   "ams-canal",
                   cash_movements(%{
                     "converted_to_credit_cents" => -100,
                     "charged_back_cents" => 100
                   })
                 )
               ],
               "credit" => credit_movements(%{"revoked_cents" => 110})
             }
    end

    test "opening and closing balances include the late adjustments", %{conn: conn} do
      started_history!(conn)

      apply_operation!(conn, close_operation(%{"period_end_on" => "2026-11-05"}))

      apply_operation!(
        conn,
        payment_operation(%{
          "operation_id" => "op-pay-late",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 5_000
        })
      )

      report = daily_report!(conn, "2026-11-06")

      # Ordinary movements are empty, yet the day closes 5,000 higher: the
      # balances use the late adjustment.
      assert report["cash"] == [cash_entry("ams-canal", 100, cash_movements(), 5_100)]

      assert report["late_adjustments"]["cash"] == [
               late_cash_entry("ams-canal", cash_movements(%{"received_cents" => 5_000}))
             ]

      # The next day opens where this day closed.
      report = daily_report!(conn, "2026-11-07")
      assert report["cash"] == [cash_entry("ams-canal", 5_100, cash_movements(), 5_100)]
    end
  end
end
