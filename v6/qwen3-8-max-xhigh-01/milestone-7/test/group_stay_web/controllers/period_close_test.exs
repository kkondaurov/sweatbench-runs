defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Finance.Movement
  alias GroupStay.Repo

  @batch_path "/api/v1/partner-batches"
  @report_path "/api/v1/finance/daily-report"
  @ledger_path "/api/v1/ledger"

  @zero_cash_movements %{
    "received_cents" => 0,
    "transferred_in_cents" => 0,
    "transferred_out_cents" => 0,
    "refunded_cents" => 0,
    "retained_cents" => 0,
    "converted_to_credit_cents" => 0,
    "reduced_cents" => 0,
    "charged_back_cents" => 0
  }

  @zero_credit_movements %{
    "issued_cents" => 0,
    "expired_cents" => 0,
    "consumed_cents" => 0,
    "revoked_cents" => 0,
    "absorbed_cents" => 0
  }

  @no_late_adjustments %{
    "cash" => [],
    "credit" => @zero_credit_movements
  }

  defp open_group_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp payment_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp start_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-05",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
  end

  defp close_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-close",
        "type" => "close_finance_period",
        "occurred_on" => "2026-10-11",
        "period_end_on" => "2026-10-10"
      },
      overrides
    )
  end

  defp cancel_group_op(operation_id, group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-10-07",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp chargeback_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-09",
        "payment_operation_id" => "pay-1"
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [open_group_op(overrides)])
    assert result["status"] == "applied"
    conn
  end

  defp open_second_group(conn, overrides \\ %{}) do
    open_group(
      conn,
      Map.merge(
        %{
          "operation_id" => "open-92",
          "group_id" => "group-92",
          "property_id" => "ber-mitte",
          "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 10000}]
        },
        overrides
      )
    )
  end

  defp pay(conn, op_id, group_id, amount_cents, overrides \\ %{}) do
    {conn, [result]} =
      post_batch(conn, [
        payment_op(
          Map.merge(overrides, %{
            "operation_id" => op_id,
            "group_id" => group_id,
            "amount_cents" => amount_cents
          })
        )
      ])

    assert result["status"] == "applied"
    conn
  end

  defp start_reporting(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [start_op(overrides)])
    assert result["status"] == "applied"
    conn
  end

  defp close_period(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [close_op(overrides)])
    {conn, result}
  end

  # Gives guest-22 a 6600 hotel-credit lot by refundably cancelling a funded
  # group with hotel credit.
  defp issue_credit(conn) do
    conn =
      open_group(conn, %{
        "operation_id" => "open-70",
        "group_id" => "group-70",
        "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 10000}]
      })

    conn = pay(conn, "pay-70", "group-70", 6000)

    {conn, [result]} =
      post_batch(conn, [
        cancel_group_op("cancel-70", "group-70", %{
          "occurred_on" => "2026-10-04",
          "refund_method" => "hotel_credit"
        })
      ])

    assert result["credit_issued_cents"] == 6600
    conn
  end

  defp apply_credit(conn, op_id, group_id, amount_cents, overrides) do
    {conn, [result]} =
      post_batch(conn, [
        Map.merge(
          %{
            "operation_id" => op_id,
            "type" => "apply_hotel_credit",
            "occurred_on" => "2026-10-05",
            "group_id" => group_id,
            "amount_cents" => amount_cents
          },
          overrides
        )
      ])

    assert result["status"] == "applied"
    conn
  end

  defp get_report(conn, date) do
    conn = get(conn, @report_path, %{"date" => date})
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_report_body(conn, date) do
    conn = get(conn, @report_path, %{"date" => date})
    {conn, response(conn, 200)}
  end

  defp get_ledger(conn) do
    conn = get(conn, @ledger_path)
    {conn, json_response(conn, 200)["data"]}
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp late_cash_entry(report, property_id) do
    Enum.find(report["late_adjustments"]["cash"], &(&1["property_id"] == property_id))
  end

  describe "close_finance_period" do
    test "the applied result contains exactly operation_id, status, and period_end_on", %{
      conn: conn
    } do
      conn = start_reporting(conn)
      {conn, result} = close_period(conn)

      assert result == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-10-10"
             }

      conn = get(conn, "/api/v1/operations/op-close")
      assert json_response(conn, 200)["data"] == result
    end

    test "is rejected before reporting has started", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, [close_op()])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "is rejected when period_end_on is before starts_on", %{conn: conn} do
      conn = start_reporting(conn)
      {_conn, [result]} = post_batch(conn, [close_op(%{"period_end_on" => "2026-09-30"})])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "is rejected for the same cutoff as the latest successful close", %{conn: conn} do
      conn = start_reporting(conn)
      {conn, first} = close_period(conn)
      assert first["status"] == "applied"

      {_conn, [result]} =
        post_batch(conn, [close_op(%{"operation_id" => "op-close-2"})])

      assert result == %{
               "operation_id" => "op-close-2",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      # the rejection did not advance the cutoff: a strictly later close
      # still applies
      {_conn, [later]} =
        post_batch(conn, [
          close_op(%{"operation_id" => "op-close-3", "period_end_on" => "2026-10-31"})
        ])

      assert later["status"] == "applied"
    end

    test "is rejected for an earlier cutoff than the latest successful close", %{conn: conn} do
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      {_conn, [result]} =
        post_batch(conn, [
          close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-10-05"})
        ])

      assert result == %{
               "operation_id" => "op-close-2",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "a strictly later close applies", %{conn: conn} do
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      {conn, [result]} =
        post_batch(conn, [
          close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-10-31"})
        ])

      assert result == %{
               "operation_id" => "op-close-2",
               "status" => "applied",
               "period_end_on" => "2026-10-31"
             }

      {_conn, report} = get_report(conn, "2026-10-31")
      assert report["status"] == "closed"

      {_conn, report} = get_report(conn, "2026-11-01")
      assert report["status"] == "open"
    end

    test "an invalid or missing period_end_on is rejected with invalid_period", %{conn: conn} do
      conn = start_reporting(conn)

      {conn, results} =
        post_batch(conn, [
          close_op(%{"operation_id" => "c-1", "period_end_on" => "not-a-date"}),
          close_op(%{"operation_id" => "c-2", "period_end_on" => "2026-02-30"}),
          close_op(%{"operation_id" => "c-3"}) |> Map.delete("period_end_on"),
          close_op(%{"operation_id" => "c-4", "period_end_on" => 20_261_010})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_period"} = result
      end

      # a valid close can still follow
      {_conn, result} = close_period(conn, %{"operation_id" => "c-5"})
      assert result["status"] == "applied"
    end

    test "a missing occurred_on is an invalid operation", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, [close_op() |> Map.delete("occurred_on")])
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end

    test "does not address a group and increments no revision", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "a retry returns the exact stored result without closing again", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, first} = close_period(conn)
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-12"})

      {conn, [retry]} = post_batch(conn, [close_op()])
      assert retry == first

      # the retry did not republish or move anything: the open day still
      # carries the later payment
      {_conn, report} = get_report(conn, "2026-10-12")
      assert report["status"] == "open"
      assert cash_entry(report, "ams-canal")["movements"]["received_cents"] == 5000
    end

    test "reusing the identifier with a different payload conflicts", %{conn: conn} do
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      {_conn, [result]} =
        post_batch(conn, [close_op(%{"period_end_on" => "2026-10-31"})])

      assert result == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end

    test "a start and a close apply in the same batch", %{conn: conn} do
      conn = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, results} =
        post_batch(conn, [
          start_op(%{}),
          close_op()
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      {conn, closed_day} = get_report(conn, "2026-10-04")
      assert closed_day["status"] == "closed"

      {_conn, first_open} = get_report(conn, "2026-10-11")
      assert first_open["status"] == "open"
    end

    test "closing exactly on starts_on applies", %{conn: conn} do
      conn = start_reporting(conn)
      {conn, result} = close_period(conn, %{"period_end_on" => "2026-10-01"})
      assert result["status"] == "applied"

      {conn, closed_day} = get_report(conn, "2026-10-01")
      assert closed_day["status"] == "closed"

      {_conn, first_open} = get_report(conn, "2026-10-02")
      assert first_open["status"] == "open"
    end
  end

  describe "publishing through the cutoff" do
    test "reports through the cutoff are closed and later reports are open", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = close_period(conn)

      {conn, on_cutoff} = get_report(conn, "2026-10-10")
      assert on_cutoff["status"] == "closed"

      {conn, before_cutoff} = get_report(conn, "2026-10-04")
      assert before_cutoff["status"] == "closed"
      assert cash_entry(before_cutoff, "ams-canal")["movements"]["received_cents"] == 5000

      {_conn, after_cutoff} = get_report(conn, "2026-10-11")
      assert after_cutoff["status"] == "open"
    end

    test "dates before starts_on stay unavailable after a close", %{conn: conn} do
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      conn = get(conn, @report_path, %{"date" => "2026-09-30"})
      assert json_response(conn, 404)["error"] == %{"code" => "report_not_available"}
    end

    test "a closed report stays byte-for-byte stable across later operations", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = close_period(conn)

      {conn, stored_body} = get_report_body(conn, "2026-10-04")

      # an old-dated late adjustment, an open-period payment, and another close
      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-02"})
      conn = pay(conn, "pay-3", "group-81", 1000, %{"occurred_on" => "2026-10-12"})

      {conn, _} =
        close_period(conn, %{"operation_id" => "close-2", "period_end_on" => "2026-10-15"})

      {_conn, later_body} = get_report_body(conn, "2026-10-04")
      assert later_body == stored_body
    end

    test "a closed report is served from its stored form", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = close_period(conn)

      {conn, stored_body} = get_report_body(conn, "2026-10-04")

      # an anomalous movement posted into the closed range cannot change the
      # published report
      %Movement{}
      |> Movement.create_changeset(%{
        posting_date: ~D[2026-10-04],
        kind: "received",
        amount_cents: 999,
        property_id: "ams-canal"
      })
      |> Repo.insert!()

      {_conn, later_body} = get_report_body(conn, "2026-10-04")
      assert later_body == stored_body
    end

    test "a second close publishes the following days and keeps earlier closed reports", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = close_period(conn)
      {conn, first_body} = get_report_body(conn, "2026-10-10")

      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-12"})

      {conn, _} =
        close_period(conn, %{"operation_id" => "close-2", "period_end_on" => "2026-10-13"})

      {conn, second} = get_report(conn, "2026-10-12")
      assert second["status"] == "closed"
      assert cash_entry(second, "ams-canal")["movements"]["received_cents"] == 2000

      {conn, boundary} = get_report(conn, "2026-10-13")
      assert boundary["status"] == "closed"

      {conn, later} = get_report(conn, "2026-10-14")
      assert later["status"] == "open"

      {_conn, first_again} = get_report_body(conn, "2026-10-10")
      assert first_again == first_body
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts on the first open day", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = close_period(conn)

      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-02"})

      # the closed day the payment occurred on is unchanged
      {conn, closed_day} = get_report(conn, "2026-10-02")
      assert closed_day["status"] == "closed"
      assert cash_entry(closed_day, "ams-canal") == nil

      # the complete effect posts on the first open day
      {conn, first_open} = get_report(conn, "2026-10-11")
      entry = cash_entry(first_open, "ams-canal")
      assert entry["opening_held_cents"] == 5000
      assert entry["closing_held_cents"] == 7000

      {_conn, next_day} = get_report(conn, "2026-10-12")
      assert cash_entry(next_day, "ams-canal")["opening_held_cents"] == 7000
    end

    test "an operation already in the open period keeps its occurred_on", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-15"})

      {_conn, report} = get_report(conn, "2026-10-15")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 5000

      {_conn, first_open} = get_report(conn, "2026-10-11")
      assert cash_entry(first_open, "ams-canal") == nil
    end

    test "in a batch, operations before a close post into the closed period and after on the first open day",
         %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)

      {conn, results} =
        post_batch(conn, [
          payment_op(%{
            "operation_id" => "pay-1",
            "occurred_on" => "2026-10-09",
            "amount_cents" => 3000
          }),
          close_op(),
          payment_op(%{
            "operation_id" => "pay-2",
            "occurred_on" => "2026-10-02",
            "amount_cents" => 1000
          })
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      # the operation immediately before the close posted into the period
      # being closed
      {conn, closed_day} = get_report(conn, "2026-10-09")
      assert closed_day["status"] == "closed"
      assert cash_entry(closed_day, "ams-canal")["movements"]["received_cents"] == 3000

      # the old-dated operation immediately after the close posted on the
      # first open day
      {_conn, first_open} = get_report(conn, "2026-10-11")
      entry = cash_entry(first_open, "ams-canal")
      assert entry["opening_held_cents"] == 3000
      assert entry["closing_held_cents"] == 4000
    end

    test "an operation keeps its posting date when a later close passes over it", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-01"})

      {conn, first_open} = get_report(conn, "2026-10-11")
      assert cash_entry(first_open, "ams-canal")["closing_held_cents"] == 5000

      {conn, _} =
        close_period(conn, %{"operation_id" => "close-2", "period_end_on" => "2026-10-20"})

      # the movement stayed on the day it committed; the later close did not
      # move it to the new first open day
      {conn, closed_day} = get_report(conn, "2026-10-11")
      assert closed_day["status"] == "closed"
      assert cash_entry(closed_day, "ams-canal")["closing_held_cents"] == 5000

      {_conn, new_first_open} = get_report(conn, "2026-10-21")
      entry = cash_entry(new_first_open, "ams-canal")
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"] == @zero_cash_movements
      assert new_first_open["late_adjustments"] == @no_late_adjustments
    end

    test "a close changes only finance reporting", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, group_before} = get_ledger_and_group(conn)
      {conn, _} = close_period(conn)
      {_conn, group_after} = get_ledger_and_group(conn)

      assert group_before == group_after
    end
  end

  describe "late adjustments" do
    test "a pushed-forward payment is reported as a late adjustment", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = close_period(conn)
      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-02"})

      {_conn, report} = get_report(conn, "2026-10-11")

      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == @zero_cash_movements
      assert entry["opening_held_cents"] == 5000
      assert entry["closing_held_cents"] == 7000

      assert report["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{@zero_cash_movements | "received_cents" => 2000}
                 }
               ],
               "credit" => @zero_credit_movements
             }
    end

    test "the late-adjustment cash array is ordered by property_id and omits all-zero properties",
         %{conn: conn} do
      conn = open_group(conn)
      conn = open_second_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      conn = pay(conn, "pay-1", "group-92", 1000, %{"occurred_on" => "2026-10-01"})
      conn = pay(conn, "pay-2", "group-81", 500, %{"occurred_on" => "2026-10-02"})

      {_conn, report} = get_report(conn, "2026-10-11")

      assert Enum.map(report["late_adjustments"]["cash"], & &1["property_id"]) ==
               ["ams-canal", "ber-mitte"]

      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 500
      assert late_cash_entry(report, "ber-mitte")["movements"]["received_cents"] == 1000

      # a property with no late movements is omitted
      {conn, _} =
        close_period(conn, %{"operation_id" => "close-2", "period_end_on" => "2026-10-12"})

      conn = pay(conn, "pay-3", "group-92", 700, %{"occurred_on" => "2026-10-03"})

      {_conn, report} = get_report(conn, "2026-10-13")

      assert report["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ber-mitte",
                 "movements" => %{@zero_cash_movements | "received_cents" => 700}
               }
             ]
    end

    test "signed classifications survive a zero net balance effect", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-10-07"})
        ])

      {conn, _} = close_period(conn, %{"period_end_on" => "2026-10-08"})

      # the chargeback occurs on a closed day and is processed after the close
      {conn, [chargeback]} =
        post_batch(conn, [chargeback_op(%{"occurred_on" => "2026-10-05"})])

      assert chargeback["charged_back_cents"] == 5000

      {_conn, report} = get_report(conn, "2026-10-09")

      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"] == @zero_cash_movements
      assert entry["closing_held_cents"] == 0

      assert late_cash_entry(report, "ams-canal")["movements"] == %{
               @zero_cash_movements
               | "refunded_cents" => -5000,
                 "charged_back_cents" => 5000
             }
    end

    test "a pushed-forward settlement reports credit late adjustments", %{conn: conn} do
      conn = issue_credit(conn)
      conn = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 3000, %{"occurred_on" => "2026-10-04"})
      conn = start_reporting(conn, %{"starts_on" => "2026-10-05"})
      {conn, _} = close_period(conn, %{"period_end_on" => "2026-12-05"})

      # non-refundable on 2026-12-01: inside the closed period, so the
      # consumption posts on the first open day
      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-12-01"})
        ])

      {_conn, report} = get_report(conn, "2026-12-06")

      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["opening_liability_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 3600

      assert report["late_adjustments"]["credit"] == %{
               @zero_credit_movements
               | "consumed_cents" => 3000
             }
    end

    test "ordinary and late movements on the same day add up", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)

      conn = pay(conn, "pay-1", "group-81", 1000, %{"occurred_on" => "2026-10-01"})
      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-11"})

      {_conn, report} = get_report(conn, "2026-10-11")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 2000
      assert entry["closing_held_cents"] == 3000
      assert late_cash_entry(report, "ams-canal")["movements"]["received_cents"] == 1000
    end

    test "a later close keeps the late adjustments of the day it publishes", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)
      conn = pay(conn, "pay-1", "group-81", 1000, %{"occurred_on" => "2026-10-01"})

      {conn, open_day} = get_report(conn, "2026-10-11")
      assert open_day["status"] == "open"
      assert late_cash_entry(open_day, "ams-canal")["movements"]["received_cents"] == 1000

      {conn, _} =
        close_period(conn, %{"operation_id" => "close-2", "period_end_on" => "2026-10-12"})

      {_conn, closed_day} = get_report(conn, "2026-10-11")
      assert closed_day["status"] == "closed"
      assert cash_entry(closed_day, "ams-canal")["movements"] == @zero_cash_movements
      assert late_cash_entry(closed_day, "ams-canal")["movements"]["received_cents"] == 1000
      assert cash_entry(closed_day, "ams-canal")["closing_held_cents"] == 1000
    end

    test "time-based expiry remains an ordinary movement after a close", %{conn: conn} do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      {conn, _} = close_period(conn)

      # the lot expires on 2027-10-05, in the open period
      {_conn, report} = get_report(conn, "2027-10-05")
      assert report["status"] == "open"
      assert report["credit"]["movements"]["expired_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 0
      assert report["late_adjustments"] == @no_late_adjustments
    end

    test "an open report after a close has no late adjustments when nothing was moved", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = start_reporting(conn)
      {conn, _} = close_period(conn)
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-12"})

      {_conn, report} = get_report(conn, "2026-10-12")
      assert report["late_adjustments"] == @no_late_adjustments
    end

    test "a pushed-forward hotel-credit settlement reports converted and issued late", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = close_period(conn, %{"period_end_on" => "2026-12-31"})

      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert cancel["credit_issued_cents"] == 6600

      {_conn, report} = get_report(conn, "2027-01-01")

      entry = cash_entry(report, "ams-canal")
      assert entry["movements"] == @zero_cash_movements
      assert entry["closing_held_cents"] == 0

      assert late_cash_entry(report, "ams-canal")["movements"] == %{
               @zero_cash_movements
               | "converted_to_credit_cents" => 6000
             }

      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["closing_liability_cents"] == 6600

      assert report["late_adjustments"]["credit"] == %{
               @zero_credit_movements
               | "issued_cents" => 6600
             }
    end

    test "a lot issued late whose expiry falls in the closed period nets to nothing", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = close_period(conn, %{"period_end_on" => "2027-12-31"})

      # the lot expires on 2027-11-02, inside the closed period, but its
      # issuance only posts on the first open day
      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        ])

      assert cancel["credit_issued_cents"] == 6600

      {_conn, report} = get_report(conn, "2028-01-01")
      assert report["credit"]["movements"]["expired_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 0
      assert report["late_adjustments"]["credit"]["issued_cents"] == 6600
    end
  end

  describe "reconciliation" do
    test "ordinary plus late movements reconcile to the ledger across closes", %{conn: conn} do
      conn = open_group(conn)
      conn = open_second_group(conn)
      conn = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = close_period(conn)

      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-02"})
      conn = pay(conn, "pay-3", "group-92", 1000, %{"occurred_on" => "2026-10-03"})

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "op-transfer",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-12",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 1000
          }
        ])

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"occurred_on" => "2026-10-13"})
        ])

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 6000
      assert ledger["cash_refunded_cents"] == 2000

      totals =
        Enum.reduce(
          ~w(2026-10-04 2026-10-11 2026-10-12 2026-10-13),
          %{},
          fn date, acc ->
            {_conn, report} = get_report(conn, date)

            day_totals =
              Enum.reduce(report["cash"], %{}, fn entry, acc ->
                acc
                |> add_movements(entry["movements"])
                |> add_movements(late_movements_for(report, entry["property_id"]))
              end)

            Map.merge(acc, day_totals, fn _kind, a, b -> a + b end)
          end
        )

      assert totals["received_cents"] == 8000
      assert totals["transferred_out_cents"] == 1000
      assert totals["transferred_in_cents"] == 1000
      assert totals["refunded_cents"] == 2000

      {_conn, final} = get_report(conn, "2026-10-13")

      closing =
        final["cash"]
        |> Enum.map(& &1["closing_held_cents"])
        |> Enum.sum()

      assert closing == ledger["cash_held_cents"]
    end
  end

  defp get_ledger_and_group(conn) do
    {conn, ledger} = get_ledger(conn)
    conn = get(conn, "/api/v1/groups/group-81")
    group = json_response(conn, 200)["data"]
    {conn, %{"ledger" => ledger, "group" => group}}
  end

  defp late_movements_for(report, property_id) do
    case late_cash_entry(report, property_id) do
      nil -> @zero_cash_movements
      entry -> entry["movements"]
    end
  end

  defp add_movements(acc, movements) do
    Enum.reduce(movements, acc, fn {kind, amount}, acc ->
      Map.update(acc, kind, amount, &(&1 + amount))
    end)
  end
end
