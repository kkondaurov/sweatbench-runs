defmodule GroupStayWeb.DailyFinanceReportAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of the daily finance report: starting reporting
  captures the opening position on starts_on, each day's report brackets that
  day's movements with the position at the start and end of the day, credit
  expiry appears even on days without operations, and reports reconcile with
  the existing current views without ever changing state.
  """

  use GroupStayWeb.ConnCase

  @batch_path "/api/v1/partner-batches"
  @report_path "/api/v1/finance/daily-report"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
  end

  defp run(conn, operations) do
    submit(conn, operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp report(conn, date) do
    conn |> get("#{@report_path}?date=#{date}") |> json_response(200) |> Map.fetch!("data")
  end

  defp report_error(conn, date, status) do
    conn |> get("#{@report_path}?date=#{date}") |> json_response(status)
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp open_op(overrides \\ %{}) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  # group-92: same guest, other property, deposits of 6_000 and 7_200.
  defp second_open_op(overrides \\ %{}) do
    Map.merge(
      open_op(%{
        "operation_id" => "op-open-92",
        "group_id" => "group-92",
        "property_id" => "rot-canal",
        "rooms" => [
          %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-d", "nightly_rate_cents" => 12_000}
        ]
      }),
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-02",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-11-01",
        "starts_on" => "2026-11-01"
      },
      overrides
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-11-03",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 3_000
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-03",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp credit_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-05",
        "group_id" => "group-81",
        "amount_cents" => 2_200
      },
      overrides
    )
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  # Opens group-81, pays it, and cancels it into hotel credit so the guest
  # holds one credit lot worth 110% of the paid cash.
  defp issue_credit(conn, cancel_op_id, group_id, cash_cents, occurred_on) do
    run(conn, [
      open_op(%{"operation_id" => cancel_op_id <> "-open", "group_id" => group_id}),
      payment_op(%{
        "operation_id" => cancel_op_id <> "-pay",
        "group_id" => group_id,
        "amount_cents" => cash_cents,
        "occurred_on" => occurred_on
      }),
      cancel_op(%{
        "operation_id" => cancel_op_id,
        "group_id" => group_id,
        "occurred_on" => occurred_on,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  describe "start_finance_reporting" do
    test "the first applied start enables reporting and reports exactly its fields", %{
      conn: conn
    } do
      assert [result] = run(conn, [start_op()])

      assert result == %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => "2026-11-01"
             }

      assert report(conn, "2026-11-01")["date"] == "2026-11-01"
    end

    test "a missing or invalid starts_on is rejected as invalid_reporting_date", %{conn: conn} do
      assert [missing] = run(conn, [start_op(%{"starts_on" => nil})])

      assert missing == %{
               "operation_id" => "op-start",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      assert [invalid] =
               run(conn, [start_op(%{"operation_id" => "op-start-2", "starts_on" => "tomorrow"})])

      assert invalid["status"] == "rejected"
      assert invalid["code"] == "invalid_reporting_date"

      # A rejected start does not enable reporting.
      assert report_error(conn, "2026-11-01", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "once reporting has started, a different start operation is rejected", %{conn: conn} do
      assert [_] = run(conn, [start_op()])

      assert [rejected] =
               run(conn, [
                 start_op(%{"operation_id" => "op-start-2", "starts_on" => "2026-12-01"})
               ])

      assert rejected == %{
               "operation_id" => "op-start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      # The original inception point is unchanged: the later date remains
      # served from the original start.
      assert report(conn, "2026-12-01")["date"] == "2026-12-01"

      assert report_error(conn, "2026-10-31", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "a retry of the original start returns the stored result without recapturing", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op()])
      assert [first] = run(conn, [start_op()])
      assert [retry] = run(conn, [start_op()])
      assert retry == first

      stored =
        conn
        |> get("/api/v1/operations/op-start")
        |> json_response(200)
        |> Map.fetch!("data")

      assert stored == first

      # The opening position was captured exactly once.
      assert cash_entry(report(conn, "2026-11-01"), "ams-canal")["opening_held_cents"] == 5_000
    end

    test "reusing the start identifier with a different payload conflicts", %{conn: conn} do
      assert [_] = run(conn, [start_op()])

      assert [conflict] = run(conn, [start_op(%{"starts_on" => "2026-11-02"})])

      assert conflict == %{
               "operation_id" => "op-start",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end
  end

  describe "report availability" do
    test "before reporting has started the report is unavailable", %{conn: conn} do
      assert report_error(conn, "2026-11-01", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "a missing or invalid date is invalid_reporting_date", %{conn: conn} do
      assert [_] = run(conn, [start_op()])

      assert report_error(conn, nil, 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert report_error(conn, "not-a-date", 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    test "an invalid date is rejected even before reporting has started", %{conn: conn} do
      assert report_error(conn, "not-a-date", 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }
    end

    test "a date before starts_on is unavailable", %{conn: conn} do
      assert [_] = run(conn, [start_op()])

      assert report_error(conn, "2026-10-31", 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      assert report(conn, "2026-11-01")["status"] == "open"
    end
  end

  describe "opening position" do
    test "committed operations become the opening position on starts_on", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"occurred_on" => "2026-10-04"})])

      assert [_, _] =
               run(conn, [
                 second_open_op(),
                 payment_op(%{
                   "operation_id" => "op-pay-92",
                   "group_id" => "group-92",
                   "amount_cents" => 2_000,
                   "occurred_on" => "2026-10-20"
                 })
               ])

      assert [_] = run(conn, [start_op()])

      report = report(conn, "2026-11-01")

      assert report["status"] == "open"
      assert report["date"] == "2026-11-01"

      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 5_000
      assert ams["closing_held_cents"] == 5_000

      assert ams["movements"] == %{
               "received_cents" => 0,
               "transferred_in_cents" => 0,
               "transferred_out_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      rot = cash_entry(report, "rot-canal")
      assert rot["opening_held_cents"] == 2_000
      assert rot["closing_held_cents"] == 2_000

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 0
             }
    end

    test "committed operations with an occurred_on on or after starts_on open the position", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [payment_op(%{"occurred_on" => "2026-11-05"})])
      assert [_] = run(conn, [start_op()])

      report = report(conn, "2026-11-01")
      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 5_000
      assert ams["movements"]["received_cents"] == 0
      assert ams["closing_held_cents"] == 5_000

      # The payment is opening position, not a movement on its occurred_on.
      later = cash_entry(report(conn, "2026-11-05"), "ams-canal")
      assert later["opening_held_cents"] == 5_000
      assert later["movements"]["received_cents"] == 0
      assert later["closing_held_cents"] == 5_000
    end

    test "in one batch, operations before the start open and operations after it move", %{
      conn: conn
    } do
      assert [_, _, _, _] =
               run(conn, [
                 open_op(),
                 payment_op(%{"occurred_on" => "2026-10-04"}),
                 start_op(),
                 payment_op(%{
                   "operation_id" => "op-pay-2",
                   "occurred_on" => "2026-11-01",
                   "amount_cents" => 1_000
                 })
               ])

      report = report(conn, "2026-11-01")
      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 5_000
      assert ams["movements"]["received_cents"] == 1_000
      assert ams["closing_held_cents"] == 6_000
    end

    test "an operation processed after the start posts to the later of occurred_on and starts_on",
         %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])

      # occurred_on before starts_on posts to starts_on.
      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-early",
                   "occurred_on" => "2026-10-15",
                   "amount_cents" => 1_000
                 })
               ])

      # occurred_on after starts_on posts to occurred_on.
      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-late",
                   "occurred_on" => "2026-11-03",
                   "amount_cents" => 2_000
                 })
               ])

      on_start = cash_entry(report(conn, "2026-11-01"), "ams-canal")
      assert on_start["opening_held_cents"] == 0
      assert on_start["movements"]["received_cents"] == 1_000
      assert on_start["closing_held_cents"] == 1_000

      on_second = cash_entry(report(conn, "2026-11-02"), "ams-canal")
      assert on_second["opening_held_cents"] == 1_000
      assert on_second["movements"]["received_cents"] == 0
      assert on_second["closing_held_cents"] == 1_000

      on_third = cash_entry(report(conn, "2026-11-03"), "ams-canal")
      assert on_third["opening_held_cents"] == 1_000
      assert on_third["movements"]["received_cents"] == 2_000
      assert on_third["closing_held_cents"] == 3_000
    end

    test "a later submission can change an earlier open report", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])

      # Nothing has moved yet, so the property is omitted entirely.
      assert report(conn, "2026-11-02")["cash"] == []

      assert [_] = run(conn, [payment_op(%{"occurred_on" => "2026-11-02"})])

      ams = cash_entry(report(conn, "2026-11-02"), "ams-canal")
      assert ams["movements"]["received_cents"] == 5_000
      assert ams["closing_held_cents"] == 5_000
    end
  end

  describe "cash movements" do
    setup %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])
      :ok
    end

    test "a payment is received where the group is held", %{conn: conn} do
      assert [_] = run(conn, [payment_op()])

      assert report(conn, "2026-11-02") == %{
               "date" => "2026-11-02",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => %{
                     "received_cents" => 5_000,
                     "transferred_in_cents" => 0,
                     "transferred_out_cents" => 0,
                     "refunded_cents" => 0,
                     "retained_cents" => 0,
                     "converted_to_credit_cents" => 0,
                     "reduced_cents" => 0,
                     "charged_back_cents" => 0
                   },
                   "closing_held_cents" => 5_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 },
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{
                 "cash" => [],
                 "credit" => %{
                   "issued_cents" => 0,
                   "expired_cents" => 0,
                   "consumed_cents" => 0,
                   "revoked_cents" => 0,
                   "absorbed_cents" => 0
                 }
               }
             }
    end

    test "a refundable cash cancellation reports refunded where the cash is held", %{conn: conn} do
      assert [_] = run(conn, [payment_op()])
      assert [cancelled] = run(conn, [cancel_op()])
      assert cancelled["refunded_cents"] == 5_000

      ams = cash_entry(report(conn, "2026-11-03"), "ams-canal")
      assert ams["opening_held_cents"] == 5_000
      assert ams["movements"]["refunded_cents"] == 5_000
      assert ams["closing_held_cents"] == 0
    end

    test "a non-refundable cancellation reports retained", %{conn: conn} do
      assert [_] = run(conn, [payment_op()])

      assert [_] = run(conn, [cancel_op(%{"occurred_on" => "2026-12-01"})])

      ams = cash_entry(report(conn, "2026-12-01"), "ams-canal")
      assert ams["opening_held_cents"] == 5_000
      assert ams["movements"]["retained_cents"] == 5_000
      assert ams["movements"]["refunded_cents"] == 0
      assert ams["closing_held_cents"] == 0
    end

    test "a conversion reports converted cash and issued liability", %{conn: conn} do
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 2_000})])
      assert [_] = run(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])

      report = report(conn, "2026-11-03")
      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 2_000
      assert ams["movements"]["converted_to_credit_cents"] == 2_000
      assert ams["closing_held_cents"] == 0

      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["movements"]["issued_cents"] == 2_200
      assert report["credit"]["closing_liability_cents"] == 2_200
    end

    test "transfers report out of the source property and into the destination property", %{
      conn: conn
    } do
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [payment_op()])
      assert [_] = run(conn, [transfer_op()])

      report = report(conn, "2026-11-03")

      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 5_000
      assert ams["movements"]["transferred_out_cents"] == 3_000
      assert ams["movements"]["transferred_in_cents"] == 0
      assert ams["closing_held_cents"] == 2_000

      rot = cash_entry(report, "rot-canal")
      assert rot["opening_held_cents"] == 0
      assert rot["movements"]["transferred_in_cents"] == 3_000
      assert rot["closing_held_cents"] == 3_000

      # Across all properties on a date, transferred in equals transferred out.
      {moved_in, moved_out} =
        Enum.reduce(report["cash"], {0, 0}, fn entry, {into, outof} ->
          {into + entry["movements"]["transferred_in_cents"],
           outof + entry["movements"]["transferred_out_cents"]}
        end)

      assert moved_in == moved_out
      assert moved_in == 3_000
    end

    test "a transfer of credit funding moves no cash", %{conn: conn} do
      # A funder group on its own property cancels into hotel credit.
      assert [_, _, _] =
               run(conn, [
                 open_op(%{
                   "operation_id" => "op-open-fund",
                   "group_id" => "group-fund",
                   "property_id" => "fund-canal",
                   "occurred_on" => "2026-11-02"
                 }),
                 payment_op(%{
                   "operation_id" => "op-pay-fund",
                   "group_id" => "group-fund",
                   "amount_cents" => 2_000,
                   "occurred_on" => "2026-11-02"
                 }),
                 cancel_op(%{
                   "operation_id" => "op-cancel-fund",
                   "group_id" => "group-fund",
                   "occurred_on" => "2026-11-02",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 1_000})])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 2_000})])

      # The transfer draws the credit (most recently allocated) plus 500 cash.
      assert [result] = run(conn, [transfer_op(%{"amount_cents" => 2_500})])
      assert result["status"] == "applied"

      report = report(conn, "2026-11-03")

      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 1_000
      assert ams["movements"]["transferred_out_cents"] == 500
      assert ams["closing_held_cents"] == 500

      rot = cash_entry(report, "rot-canal")
      assert rot["movements"]["transferred_in_cents"] == 500
      assert rot["closing_held_cents"] == 500

      # The credit portion moves without cash and without liability change.
      assert report["credit"]["closing_liability_cents"] == 2_200
      assert ledger(conn)["cash_held_cents"] == 1_000
    end

    test "rejected operations leave no movement and earlier applied movements remain", %{
      conn: conn
    } do
      assert [applied, rejected] =
               run(conn, [
                 payment_op(%{"amount_cents" => 1_000}),
                 payment_op(%{"operation_id" => "op-pay-too-much", "amount_cents" => 99_000})
               ])

      assert applied["status"] == "applied"
      assert rejected["status"] == "rejected"

      ams = cash_entry(report(conn, "2026-11-02"), "ams-canal")
      assert ams["movements"]["received_cents"] == 1_000
      assert ams["closing_held_cents"] == 1_000
    end

    test "a durable retry does not report the movement twice", %{conn: conn} do
      assert [_] = run(conn, [payment_op()])
      assert [retry] = run(conn, [payment_op()])
      assert retry["status"] == "applied"

      ams = cash_entry(report(conn, "2026-11-02"), "ams-canal")
      assert ams["movements"]["received_cents"] == 5_000
      assert ams["closing_held_cents"] == 5_000
    end

    test "properties with no position or movement are omitted and entries order by property_id",
         %{conn: conn} do
      assert [_] = run(conn, [second_open_op()])

      assert [_] =
               run(conn, [payment_op(%{"group_id" => "group-92", "operation_id" => "op-pay-92"})])

      report = report(conn, "2026-11-02")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["rot-canal"]

      assert [_] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-81", "amount_cents" => 1_000})])

      report = report(conn, "2026-11-02")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "rot-canal"]
    end
  end

  describe "corrections follow the cash" do
    setup %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [payment_op()])
      assert [_] = run(conn, [transfer_op()])
      :ok
    end

    test "a reduction reports where the cash is now held", %{conn: conn} do
      # The transfer drew 3_000 into rot-canal most recently, so the reduction
      # removes it there, not at the payment's original property.
      assert [reduced] =
               run(conn, [
                 %{
                   "operation_id" => "op-reduce",
                   "type" => "reduce_cash_payment",
                   "occurred_on" => "2026-11-04",
                   "payment_operation_id" => "op-pay",
                   "amount_cents" => 1_000
                 }
               ])

      assert reduced["status"] == "applied"

      report = report(conn, "2026-11-04")

      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 2_000
      assert ams["movements"]["reduced_cents"] == 0
      assert ams["closing_held_cents"] == 2_000

      rot = cash_entry(report, "rot-canal")
      assert rot["opening_held_cents"] == 3_000
      assert rot["movements"]["reduced_cents"] == 1_000
      assert rot["closing_held_cents"] == 2_000
    end

    test "a chargeback reports where the cash is held or was settled", %{conn: conn} do
      assert [charged_back] =
               run(conn, [
                 %{
                   "operation_id" => "op-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-11-04",
                   "payment_operation_id" => "op-pay"
                 }
               ])

      assert charged_back["status"] == "applied"
      assert charged_back["charged_back_cents"] == 5_000

      report = report(conn, "2026-11-04")

      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 2_000
      assert ams["movements"]["charged_back_cents"] == 2_000
      assert ams["closing_held_cents"] == 0

      rot = cash_entry(report, "rot-canal")
      assert rot["opening_held_cents"] == 3_000
      assert rot["movements"]["charged_back_cents"] == 3_000
      assert rot["closing_held_cents"] == 0
    end

    test "charging back an earlier refund reports negative refunded with positive charged back",
         %{conn: conn} do
      # Settle group-92's transferred cash refundably at rot-canal.
      assert [refunded] =
               run(conn, [cancel_op(%{"group_id" => "group-92", "occurred_on" => "2026-11-04"})])

      assert refunded["refunded_cents"] == 3_000

      on_refund = cash_entry(report(conn, "2026-11-04"), "rot-canal")
      assert on_refund["movements"]["refunded_cents"] == 3_000
      assert on_refund["closing_held_cents"] == 0

      assert [_] =
               run(conn, [
                 %{
                   "operation_id" => "op-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-11-05",
                   "payment_operation_id" => "op-pay"
                 }
               ])

      report = report(conn, "2026-11-05")

      rot = cash_entry(report, "rot-canal")
      assert rot["movements"]["refunded_cents"] == -3_000
      assert rot["movements"]["charged_back_cents"] == 3_000
      assert rot["closing_held_cents"] == 0

      ams = cash_entry(report, "ams-canal")
      assert ams["opening_held_cents"] == 2_000
      assert ams["movements"]["charged_back_cents"] == 2_000
      assert ams["closing_held_cents"] == 0
    end
  end

  describe "credit movements" do
    test "applying and restoring credit changes no liability and reports no movement", %{
      conn: conn
    } do
      assert [_] = run(conn, [start_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")
      assert [_] = run(conn, [open_op()])
      assert [applied] = run(conn, [credit_op()])
      assert applied["status"] == "applied"

      after_apply = report(conn, "2026-11-05")["credit"]
      assert after_apply["opening_liability_cents"] == 2_200

      assert after_apply["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert after_apply["closing_liability_cents"] == 2_200

      # Refundable cancellation restores the credit to its lot: still no
      # liability movement.
      assert [_] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-06"})])

      after_restore = report(conn, "2026-11-06")["credit"]
      assert after_restore["opening_liability_cents"] == 2_200

      assert after_restore["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert after_restore["closing_liability_cents"] == 2_200
    end

    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [credit_op()])
      assert [_] = run(conn, [cancel_op(%{"occurred_on" => "2026-12-01"})])

      credit = report(conn, "2026-12-01")["credit"]
      assert credit["opening_liability_cents"] == 2_200
      assert credit["movements"]["consumed_cents"] == 2_200
      assert credit["closing_liability_cents"] == 0
    end

    test "credit that remains unused expires on its expiry date without any operation that day",
         %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      # The lot is issued on 2026-11-02 and expires on 2027-11-03.
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")

      before_expiry = report(conn, "2027-11-02")["credit"]
      assert before_expiry["movements"]["expired_cents"] == 0
      assert before_expiry["closing_liability_cents"] == 2_200

      on_expiry = report(conn, "2027-11-03")["credit"]
      assert on_expiry["opening_liability_cents"] == 2_200
      assert on_expiry["movements"]["expired_cents"] == 2_200
      assert on_expiry["closing_liability_cents"] == 0

      # The position stays expired on later dates.
      later = report(conn, "2027-12-01")["credit"]
      assert later["opening_liability_cents"] == 0
      assert later["closing_liability_cents"] == 0
    end

    test "restoring credit to an already expired lot expires it immediately", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")

      # A stay far enough out that cancellation after the lot's expiry
      # (2027-11-03) is still refundable.
      assert [_] =
               run(conn, [
                 open_op(%{"arrival_on" => "2028-01-10", "departure_on" => "2028-01-13"})
               ])

      assert [_] = run(conn, [credit_op()])
      assert [_] = run(conn, [cancel_op(%{"occurred_on" => "2027-12-01"})])

      credit = report(conn, "2027-12-01")["credit"]
      assert credit["opening_liability_cents"] == 2_200
      assert credit["movements"]["expired_cents"] == 2_200
      assert credit["closing_liability_cents"] == 0
    end

    test "a restoration absorbed by shortfall reports absorbed", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [credit_op()])

      # Charge back the converted payment while the credit is applied: the
      # whole entitlement becomes unrecovered clawback.
      assert [_] =
               run(conn, [
                 %{
                   "operation_id" => "op-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-11-06",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 }
               ])

      assert ledger(conn)["credit_shortfall_cents"] == 2_200
      assert report(conn, "2026-11-06")["credit"]["closing_liability_cents"] == 2_200

      # Refundable settlement returns the credit to the shortfalled lot and the
      # clawback absorbs it.
      assert [_] = run(conn, [cancel_op(%{"occurred_on" => "2026-11-20"})])

      credit = report(conn, "2026-11-20")["credit"]
      assert credit["opening_liability_cents"] == 2_200
      assert credit["movements"]["absorbed_cents"] == 2_200
      assert credit["closing_liability_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "a chargeback revokes unspent entitlement from an unexpired lot", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")

      assert [_] =
               run(conn, [
                 %{
                   "operation_id" => "op-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-11-10",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 }
               ])

      credit = report(conn, "2026-11-10")["credit"]
      assert credit["opening_liability_cents"] == 2_200
      assert credit["movements"]["revoked_cents"] == 2_200
      assert credit["closing_liability_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "revoking from an already expired lot does not reduce liability again", %{conn: conn} do
      assert [_] = run(conn, [start_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-02")

      # Charge back after the lot expired (2027-11-03): the stored balance
      # shrinks but the liability was already gone with the expiry.
      assert [_] =
               run(conn, [
                 %{
                   "operation_id" => "op-chargeback",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2027-12-01",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 }
               ])

      on_expiry = report(conn, "2027-11-03")["credit"]
      assert on_expiry["movements"]["expired_cents"] == 2_200
      assert on_expiry["closing_liability_cents"] == 0

      after_chargeback = report(conn, "2027-12-01")["credit"]
      assert after_chargeback["opening_liability_cents"] == 0
      assert after_chargeback["movements"]["revoked_cents"] == 0
      assert after_chargeback["movements"]["expired_cents"] == 0
      assert after_chargeback["closing_liability_cents"] == 0
    end

    test "credit issued before the start opens the liability and can still expire", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-10-10")
      assert [_] = run(conn, [start_op()])

      report = report(conn, "2026-11-01")
      assert report["credit"]["opening_liability_cents"] == 2_200
      assert report["credit"]["closing_liability_cents"] == 2_200

      # Issued on 2026-10-10, expires on 2027-10-11.
      assert report(conn, "2027-10-10")["credit"]["closing_liability_cents"] == 2_200

      expired = report(conn, "2027-10-11")["credit"]
      assert expired["movements"]["expired_cents"] == 2_200
      assert expired["closing_liability_cents"] == 0
    end
  end

  describe "reading reports" do
    test "reports reconcile with the current views and reads never change state", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [start_op()])
      assert [_] = run(conn, [payment_op()])
      assert [_] = run(conn, [transfer_op()])
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000, "2026-11-04")
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 1_000})])

      ledger_before = ledger(conn)

      earlier = report(conn, "2026-11-05")
      later = report(conn, "2026-12-31")
      assert report(conn, "2026-11-05") == earlier

      # Held cash reconciles across properties.
      closing_held =
        Enum.reduce(later["cash"], 0, fn entry, sum -> sum + entry["closing_held_cents"] end)

      assert closing_held == ledger_before["cash_held_cents"]

      # Every property's closing follows its opening and that day's movements.
      Enum.each(later["cash"] ++ earlier["cash"], fn entry ->
        m = entry["movements"]

        assert entry["closing_held_cents"] ==
                 entry["opening_held_cents"] + m["received_cents"] +
                   m["transferred_in_cents"] - m["transferred_out_cents"] -
                   m["refunded_cents"] - m["retained_cents"] -
                   m["converted_to_credit_cents"] - m["reduced_cents"] -
                   m["charged_back_cents"]
      end)

      # A later day opens where the earlier day closed.
      assert cash_entry(later, "ams-canal")["opening_held_cents"] ==
               cash_entry(earlier, "ams-canal")["closing_held_cents"]

      assert later["credit"]["opening_liability_cents"] ==
               earlier["credit"]["closing_liability_cents"]

      # Credit liability reconciles with the ledger.
      assert later["credit"]["closing_liability_cents"] == ledger_before["credit_liability_cents"]

      assert ledger(conn) == ledger_before
    end

    test "equivalent batches and sequential submissions produce equivalent reports", %{
      conn: conn
    } do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [start_op()])

      # One batch...
      assert [_, _] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-a", "amount_cents" => 1_000}),
                 payment_op(%{"operation_id" => "op-pay-b", "amount_cents" => 2_000})
               ])

      batched = report(conn, "2026-11-02")

      # ...and the same operations retried as an equivalent batch.
      assert [retry_a, retry_b] =
               run(conn, [
                 payment_op(%{"operation_id" => "op-pay-a", "amount_cents" => 1_000}),
                 payment_op(%{"operation_id" => "op-pay-b", "amount_cents" => 2_000})
               ])

      assert retry_a["status"] == "applied"
      assert retry_b["status"] == "applied"

      assert report(conn, "2026-11-02") == batched
    end
  end
end
