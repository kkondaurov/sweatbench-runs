defmodule GroupStayWeb.PeriodCloseTest do
  @moduledoc """
  End-to-end coverage of the finance period close: closing through a date,
  publishing and freezing the daily reports it covers, the posting-date rule
  of operations processed after a close, and the late-adjustments block that
  keeps later corrections visible without rewriting a closed day.
  """

  use GroupStayWeb.ConnCase, async: false

  import GroupStay.PartnerHelpers

  alias GroupStay.Repo

  defp report(date), do: json_response(get_daily_report(date), 200)["data"]

  defp ledger(on), do: json_response(get_ledger(on), 200)["data"]

  defp cash_entry(date, property_id) do
    Enum.find(report(date)["cash"], &(&1["property_id"] == property_id))
  end

  defp late_cash_entry(date, property_id) do
    Enum.find(
      report(date)["late_adjustments"]["cash"],
      &(&1["property_id"] == property_id)
    )
  end

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

  defp cash_movements(overrides \\ %{}),
    do: Map.merge(zero_cash_movements(), overrides)

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp zero_late_adjustments do
    %{
      "cash" => [],
      "credit" => zero_credit_movements()
    }
  end

  describe "closing through a date" do
    test "applies and returns exactly operation_id, status, and period_end_on" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          start_reporting_operation("start-1", "2026-11-01"),
          close_period_operation("close-1", "2026-11-10")
        ])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2026-11-10"
             }
    end

    test "rejects an unusable period_end_on as invalid_period" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])

      conn = post_batch([close_period_operation("close-1", "not-a-date")])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      conn = post_batch([close_period_operation("close-2", nil)])

      assert result_for(conn, "close-2") == %{
               "operation_id" => "close-2",
               "status" => "rejected",
               "code" => "invalid_period"
             }
    end

    test "rejects a close before reporting has started, durably" do
      conn = post_batch([close_period_operation("close-1", "2026-11-10")])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      # a retry of the rejected close returns its stored rejection
      conn = post_batch([close_period_operation("close-1", "2026-11-10")])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      # it closed nothing: once reporting starts, that cutoff is still available
      post_batch([start_reporting_operation("start-1", "2026-11-01")])

      conn = post_batch([close_period_operation("close-2", "2026-11-10")])

      assert result_for(conn, "close-2")["status"] == "applied"
    end

    test "rejects a cutoff before starts_on, but not one on starts_on" do
      post_batch([start_reporting_operation("start-1", "2026-11-05")])

      conn = post_batch([close_period_operation("close-1", "2026-11-04")])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      conn = post_batch([close_period_operation("close-2", "2026-11-05")])

      assert result_for(conn, "close-2")["status"] == "applied"
    end

    test "rejects a different close of the same or an earlier cutoff" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])
      post_batch([close_period_operation("close-1", "2026-11-10")])

      conn = post_batch([close_period_operation("close-2", "2026-11-10")])
      assert result_for(conn, "close-2")["code"] == "invalid_period"

      conn = post_batch([close_period_operation("close-3", "2026-11-05")])
      assert result_for(conn, "close-3")["code"] == "invalid_period"

      conn = post_batch([close_period_operation("close-4", "2026-11-11")])
      assert result_for(conn, "close-4")["status"] == "applied"
    end

    test "follows the durable replay and conflict rules" do
      post_batch([start_reporting_operation("start-1", "2026-11-01")])
      post_batch([close_period_operation("close-1", "2026-11-10")])

      # a replay of the applied close returns its exact stored result
      conn = post_batch([close_period_operation("close-1", "2026-11-10")])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2026-11-10"
             }

      # and the operations endpoint reports the stored result
      assert json_response(get_operation("close-1"), 200)["data"] == %{
               "operation_id" => "close-1",
               "status" => "applied",
               "period_end_on" => "2026-11-10"
             }

      # a different payload under the same identifier conflicts
      conn = post_batch([close_period_operation("close-1", "2026-11-20")])

      assert result_for(conn, "close-1") == %{
               "operation_id" => "close-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end

    test "reports through the cutoff are closed and later reports are open" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        close_period_operation("close-1", "2026-11-10")
      ])

      assert report("2026-11-01")["status"] == "closed"
      assert report("2026-11-09")["status"] == "closed"
      assert report("2026-11-10")["status"] == "closed"
      assert report("2026-11-11")["status"] == "open"

      # closing on starts_on closes exactly that one day, with its opening
      post_batch([
        open_group_operation("op-3", %{"group_id" => "group-82"}),
        start_reporting_operation("start-2", "2026-12-01")
      ])

      conn = post_batch([close_period_operation("close-2", "2026-12-01")])

      assert result_for(conn, "close-2")["status"] == "applied"
      assert report("2026-12-01")["status"] == "closed"
      assert report("2026-12-02")["status"] == "open"
    end
  end

  describe "published reports" do
    test "a closed report keeps its exact data across later operations" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"}),
        close_period_operation("close-1", "2026-11-05")
      ])

      closed = report("2026-11-05")

      assert closed == %{
               "date" => "2026-11-05",
               "status" => "closed",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 0,
                   "movements" => cash_movements(%{"received_cents" => 5_000}),
                   "closing_held_cents" => 5_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => zero_late_adjustments()
             }

      # every day through the cutoff was published durably
      assert Repo.aggregate(GroupStay.Finance.ReportSnapshot, :count) == 5

      # later operations — old-dated and new-dated — never rewrite the day
      post_batch([
        pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-11-03"}),
        pay_operation("op-4", "group-81", 5_000, %{"occurred_on" => "2026-11-08"})
      ])

      assert report("2026-11-05") == closed
      assert report("2026-11-05") == closed
    end

    test "a later close never changes an already published day" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"}),
        close_period_operation("close-1", "2026-11-05")
      ])

      first = report("2026-11-05")

      post_batch([pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-11-07"})])

      post_batch([close_period_operation("close-2", "2026-11-10")])

      assert report("2026-11-05") == first

      # the second close published the days it added, from the state observed
      # when it was processed
      second = report("2026-11-08")

      assert second["status"] == "closed"

      assert second["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 10_000}),
                 "closing_held_cents" => 10_000
               }
             ]

      assert report("2026-11-10")["status"] == "closed"
      assert report("2026-11-11")["status"] == "open"
    end

    test "a closed day stays frozen even when later state changes would alter it" do
      post_batch([
        open_group_operation("op-1"),
        pay_operation("op-2", "group-81", 5_000),
        start_reporting_operation("start-1", "2026-11-01"),
        # lot worth 5_500 issued on 2026-11-05, expires on 2027-11-06
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        open_group_operation("op-4", %{
          "group_id" => "group-82",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        }),
        # 2_000 of the lot now fund group-82; 3_500 expire unused
        apply_credit_operation("op-5", "group-82", 2_000, %{"occurred_on" => "2026-11-10"}),
        close_period_operation("close-1", "2027-11-30")
      ])

      closed = report("2027-11-06")

      assert closed["status"] == "closed"
      assert closed["credit"]["movements"]["expired_cents"] == 3_500
      assert closed["credit"]["closing_liability_cents"] == 2_000

      # an old-dated refundable cancellation of group-82 commits after the
      # close and restores 2_000 into the already-expired lot, which would
      # change a recomputed expiry of that day — the published day never moves
      post_batch([cancel_operation("op-6", "group-82", %{"occurred_on" => "2026-11-15"})])

      assert report("2027-11-06") == closed

      # the still-open days show the restored amount from the first open day
      open_report = report("2027-12-01")

      assert open_report["status"] == "open"
      assert open_report["credit"]["movements"]["expired_cents"] == 5_500
      assert open_report["credit"]["closing_liability_cents"] == 0

      assert ledger("2027-12-01")["credit_liability_cents"] == 0
    end
  end

  describe "posting after a close" do
    test "an operation before the close posts into the period, an old-dated one after it on the first open day" do
      conn =
        post_batch([
          open_group_operation("op-1"),
          start_reporting_operation("start-1", "2026-11-01"),
          pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-05"}),
          close_period_operation("close-1", "2026-11-10"),
          pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-11-03"}),
          pay_operation("op-4", "group-81", 5_000, %{"occurred_on" => "2026-10-20"})
        ])

      assert Enum.map(results(conn), & &1["status"]) == Enum.map(1..6, fn _ -> "applied" end)

      # the payment immediately before the close is inside the closed period
      closed_entry = cash_entry("2026-11-10", "ams-canal")

      assert closed_entry["movements"] == cash_movements(%{"received_cents" => 5_000})
      assert closed_entry["closing_held_cents"] == 5_000
      assert report("2026-11-10")["late_adjustments"]["cash"] == []

      # both old-dated payments after the close post their complete finance
      # effect on the first open day, as late adjustments
      entry = cash_entry("2026-11-11", "ams-canal")

      assert entry["movements"] == cash_movements(%{"received_cents" => 5_000})
      assert entry["closing_held_cents"] == 15_000

      assert late_cash_entry("2026-11-11", "ams-canal")["movements"] ==
               cash_movements(%{"received_cents" => 10_000})

      # no earlier open day reports them either
      assert cash_entry("2026-11-09", "ams-canal")["movements"]["received_cents"] == 5_000

      # and the closing position reconciles with the ledger
      assert ledger("2026-11-11")["cash_held_cents"] == 15_000
    end

    test "an operation in the open period keeps its occurred_on and is not late" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        close_period_operation("close-1", "2026-11-10"),
        # exactly the first open day
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-11"}),
        pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-11-13"})
      ])

      entry = cash_entry("2026-11-11", "ams-canal")

      assert entry["movements"] == cash_movements(%{"received_cents" => 5_000})
      assert report("2026-11-11")["late_adjustments"]["cash"] == []

      entry = cash_entry("2026-11-13", "ams-canal")

      assert entry["movements"] == cash_movements(%{"received_cents" => 10_000})
      assert report("2026-11-13")["late_adjustments"]["cash"] == []
      assert report("2026-11-13")["late_adjustments"]["credit"] == zero_credit_movements()
    end

    test "an operation keeps the posting date chosen when it commits" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        close_period_operation("close-1", "2026-11-10"),
        # posts late on 2026-11-11
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-03"}),
        close_period_operation("close-2", "2026-11-20")
      ])

      # the later close never moved the payment's posting date: it still
      # posts on 2026-11-11, now inside the second closed period, and it is
      # still reported there as a late adjustment
      data = report("2026-11-11")

      assert data["status"] == "closed"

      entry = cash_entry("2026-11-11", "ams-canal")

      assert entry["movements"] == cash_movements()
      assert entry["closing_held_cents"] == 5_000

      assert late_cash_entry("2026-11-11", "ams-canal")["movements"] ==
               cash_movements(%{"received_cents" => 5_000})

      assert report("2026-11-20")["status"] == "closed"
      assert report("2026-11-21")["status"] == "open"
    end

    test "late adjustments accumulate through the date like ordinary movements" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        close_period_operation("close-1", "2026-11-10"),
        # posts late on 2026-11-11
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-03"}),
        close_period_operation("close-2", "2026-11-15"),
        # posts late on 2026-11-16
        pay_operation("op-3", "group-81", 5_000, %{"occurred_on" => "2026-11-12"})
      ])

      # the day the first late payment landed on is closed by the second close
      assert late_cash_entry("2026-11-11", "ams-canal")["movements"] ==
               cash_movements(%{"received_cents" => 5_000})

      # a later day reports both late movements cumulatively, and the closing
      # balance uses them together with the ordinary movements
      entry = cash_entry("2026-11-16", "ams-canal")

      assert entry["movements"] == cash_movements()
      assert entry["closing_held_cents"] == 10_000

      assert late_cash_entry("2026-11-16", "ams-canal")["movements"] ==
               cash_movements(%{"received_cents" => 10_000})

      assert ledger("2026-11-16")["cash_held_cents"] == 10_000
    end
  end

  describe "identifying late adjustments" do
    test "a late chargeback of a refund keeps both signed classifications" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-2", "group-81", 100, %{"occurred_on" => "2026-11-02"}),
        cancel_operation("op-3", "group-81", %{"occurred_on" => "2026-11-05"}),
        close_period_operation("close-1", "2026-11-10"),
        charge_back_operation("op-4", "op-2", %{"occurred_on" => "2026-11-04"})
      ])

      assert report("2026-11-11")["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" =>
                     cash_movements(%{"refunded_cents" => -100, "charged_back_cents" => 100})
                 }
               ],
               "credit" => zero_credit_movements()
             }

      # the ordinary columns keep the original movements; the day's totals and
      # balances use both
      entry = cash_entry("2026-11-11", "ams-canal")

      assert entry["movements"] ==
               cash_movements(%{"received_cents" => 100, "refunded_cents" => 100})

      assert entry["closing_held_cents"] == 0

      assert ledger("2026-11-11")["cash_refunded_cents"] == 0
      assert ledger("2026-11-11")["cash_charged_back_cents"] == 100
    end

    test "late cash entries are ordered by property_id and omit all-zero properties" do
      post_batch([
        open_group_operation("op-1"),
        open_group_operation("op-2", %{"group_id" => "group-82", "property_id" => "par-eiffel"}),
        open_group_operation("op-3", %{"group_id" => "group-83", "property_id" => "lon-kings"}),
        pay_operation("op-4", "group-81", 5_000, %{"occurred_on" => "2026-11-02"}),
        pay_operation("op-5", "group-82", 5_000, %{"occurred_on" => "2026-11-02"}),
        start_reporting_operation("start-1", "2026-11-01"),
        close_period_operation("close-1", "2026-11-10"),
        transfer_operation("op-6", "group-81", "group-82", 2_000, %{"occurred_on" => "2026-11-03"})
      ])

      late = report("2026-11-11")["late_adjustments"]["cash"]

      assert Enum.map(late, & &1["property_id"]) == ["ams-canal", "par-eiffel"]

      assert Enum.find(late, &(&1["property_id"] == "ams-canal"))["movements"] ==
               cash_movements(%{"transferred_out_cents" => 2_000})

      assert Enum.find(late, &(&1["property_id"] == "par-eiffel"))["movements"] ==
               cash_movements(%{"transferred_in_cents" => 2_000})

      # lon-kings has no movement at all, late or ordinary: omitted everywhere
      assert cash_entry("2026-11-11", "lon-kings") == nil
    end

    test "a late hotel-credit settlement reports converted cash and issued credit late" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"}),
        close_period_operation("close-1", "2026-11-10"),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        })
      ])

      data = report("2026-11-11")

      assert data["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => cash_movements(%{"converted_to_credit_cents" => 5_000})
               }
             ]

      assert data["late_adjustments"]["credit"] ==
               Map.merge(zero_credit_movements(), %{"issued_cents" => 5_500})

      entry = cash_entry("2026-11-11", "ams-canal")

      assert entry["movements"] == cash_movements(%{"received_cents" => 5_000})
      assert entry["closing_held_cents"] == 0

      credit = data["credit"]

      assert credit["movements"] == zero_credit_movements()
      assert credit["closing_liability_cents"] == 5_500

      assert ledger("2026-11-11")["credit_liability_cents"] == 5_500
    end

    test "a late chargeback of a conversion revokes credit late" do
      post_batch([
        open_group_operation("op-1"),
        start_reporting_operation("start-1", "2026-11-01"),
        pay_operation("op-2", "group-81", 5_000, %{"occurred_on" => "2026-11-02"}),
        cancel_operation("op-3", "group-81", %{
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        }),
        close_period_operation("close-1", "2026-11-10"),
        charge_back_operation("op-4", "op-2", %{"occurred_on" => "2026-11-04"})
      ])

      data = report("2026-11-11")

      assert data["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   cash_movements(%{
                     "converted_to_credit_cents" => -5_000,
                     "charged_back_cents" => 5_000
                   })
               }
             ]

      assert data["late_adjustments"]["credit"] ==
               Map.merge(zero_credit_movements(), %{"revoked_cents" => 5_500})

      entry = cash_entry("2026-11-11", "ams-canal")

      assert entry["movements"] ==
               cash_movements(%{
                 "received_cents" => 5_000,
                 "converted_to_credit_cents" => 5_000
               })

      assert entry["closing_held_cents"] == 0

      credit = data["credit"]

      assert credit["movements"]["issued_cents"] == 5_500
      assert credit["closing_liability_cents"] == 0
    end
  end
end
