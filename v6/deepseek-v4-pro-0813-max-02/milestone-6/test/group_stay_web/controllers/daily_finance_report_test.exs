defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.ApiHelpers

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.FinanceReporting.Movement

  defp post_ops(ops) do
    api_post(build_conn(), "/api/v1/partner-batches", %{"operations" => ops})
  end

  defp get_report(date) do
    api_get(build_conn(), "/api/v1/finance/daily-report?date=#{date}")
  end

  defp get_ledger(query \\ "") do
    api_get(build_conn(), "/api/v1/ledger#{query}")
  end

  defp get_payment(payment_operation_id) do
    api_get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
  end

  defp result(body, index \\ 0) do
    Enum.at(body["results"], index)
  end

  defp destination_op(overrides \\ %{}) do
    open_group_op(%{
      "operation_id" => "op-1002",
      "group_id" => "group-92",
      "occurred_on" => "2026-10-03",
      "guest_id" => "guest-22",
      "property_id" => "ams-plaza",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-x", "nightly_rate_cents" => 20_000},
        %{"room_id" => "room-y", "nightly_rate_cents" => 30_000}
      ]
    })
    |> Map.merge(overrides)
  end

  defp third_property_op(overrides \\ %{}) do
    open_group_op(%{
      "operation_id" => "op-1003",
      "group_id" => "group-93",
      "occurred_on" => "2026-10-03",
      "guest_id" => "guest-22",
      "property_id" => "ams-central",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "advance_purchase",
      "rooms" => [
        %{"room_id" => "room-p", "nightly_rate_cents" => 20_000}
      ]
    })
    |> Map.merge(overrides)
  end

  defp report_data(date) do
    {body, 200} = get_report(date)
    body["data"]
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  defp movements_of(report, property_id) do
    cash_entry(report, property_id)["movements"]
  end

  describe "starting finance reporting" do
    test "the first applied start enables reporting and returns exactly its three fields" do
      {body, 200} = post_ops([start_finance_reporting_op()])

      assert result(body) == %{
               "operation_id" => "fin-1",
               "status" => "applied",
               "starts_on" => "2026-10-03"
             }

      assert Map.keys(result(body)) |> Enum.sort() == ["operation_id", "starts_on", "status"]

      {body, 200} = get_report("2026-10-03")

      assert body["data"] == %{
               "date" => "2026-10-03",
               "status" => "open",
               "cash" => [],
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
               }
             }
    end

    test "rejects an invalid or missing starts_on as invalid_reporting_date" do
      for {starts_on, index} <-
            Enum.with_index([nil, "not-a-date", "2026-13-01", "2026-10-03T10:00:00", 42]) do
        op =
          start_finance_reporting_op(%{
            "operation_id" => "fin-#{index}",
            "starts_on" => starts_on
          })

        {body, 200} = post_ops([op])

        assert result(body) == %{
                 "operation_id" => "fin-#{index}",
                 "status" => "rejected",
                 "code" => "invalid_reporting_date"
               }
      end

      # None of the rejections enabled reporting.
      {body, 404} = get_report("2026-10-03")
      assert body == %{"error" => %{"code" => "report_not_available"}}
    end

    test "a later different start is rejected with reporting_already_started" do
      {_, 200} = post_ops([start_finance_reporting_op()])

      {body, 200} =
        post_ops([
          start_finance_reporting_op(%{
            "operation_id" => "fin-2",
            "starts_on" => "2026-11-01"
          })
        ])

      assert result(body) == %{
               "operation_id" => "fin-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      # The original start is still the inception point.
      assert report_data("2026-10-03")["date"] == "2026-10-03"
    end

    test "a retry of the original start returns the stored result" do
      {body, 200} = post_ops([start_finance_reporting_op()])
      applied = result(body)

      {retry_body, 200} = post_ops([start_finance_reporting_op()])
      assert result(retry_body) == applied

      {body, 200} =
        post_ops([
          start_finance_reporting_op(%{
            "starts_on" => "2026-12-01",
            "operation_id" => "fin-1",
            "type" => "start_finance_reporting"
          })
        ])

      assert result(body) == %{
               "operation_id" => "fin-1",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      {stored, 200} = api_get(build_conn(), "/api/v1/operations/fin-1")
      assert stored == %{"data" => applied}
    end

    test "batch operations before the start become the opening position" do
      {_, 200} =
        post_ops([
          open_group_op(),
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-20",
            "amount_cents" => 5_000
          }),
          start_finance_reporting_op()
        ])

      # The payment was committed before the start even though its
      # occurred_on is after starts_on; it is part of the opening position.
      report = report_data("2026-10-03")
      entry = cash_entry(report, "ams-canal")

      assert entry == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 5_000,
               "movements" => %{
                 "received_cents" => 0,
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
    end

    test "batch operations after the start become movements" do
      {_, 200} =
        post_ops([
          open_group_op(),
          start_finance_reporting_op(),
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      report = report_data("2026-10-05")
      entry = cash_entry(report, "ams-canal")

      assert entry == %{
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
    end

    test "credit opening positions capture liability that predates the start" do
      # Issue credit before reporting starts; the start opening captures it.
      {_, 200} =
        post_ops([
          open_group_op(),
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          }),
          start_finance_reporting_op(%{"starts_on" => "2026-10-07"})
        ])

      report = report_data("2026-10-07")

      assert report["credit"] == %{
               "opening_liability_cents" => 5_500,
               "movements" => %{
                 "issued_cents" => 0,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 5_500
             }

      # The pre-start credit still expires inside the report range.
      report = report_data("2027-10-07")
      assert report["credit"]["movements"]["expired_cents"] == 5_500
      assert report["credit"]["closing_liability_cents"] == 0
    end
  end

  describe "reading one day" do
    test "a missing or invalid date returns 422 invalid_reporting_date" do
      {body, 422} = api_get(build_conn(), "/api/v1/finance/daily-report")
      assert body == %{"error" => %{"code" => "invalid_reporting_date"}}

      for date <- ["not-a-date", "2026-13-01", "2026-10-03T00:00:00Z"] do
        {body, 422} = get_report(date)
        assert body == %{"error" => %{"code" => "invalid_reporting_date"}}
      end
    end

    test "returns 404 report_not_available before reporting or before starts_on" do
      {body, 404} = get_report("2026-10-03")
      assert body == %{"error" => %{"code" => "report_not_available"}}

      {_, 200} = post_ops([start_finance_reporting_op()])

      {body, 404} = get_report("2026-10-02")
      assert body == %{"error" => %{"code" => "report_not_available"}}

      {body, 200} = get_report("2026-10-03")
      assert body["data"]["date"] == "2026-10-03"
    end

    test "cash entries are ordered by property_id and omit all-zero properties" do
      {_, 200} =
        post_ops([
          open_group_op(),
          destination_op(),
          third_property_op(),
          start_finance_reporting_op()
        ])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          cash_payment_op(%{
            "operation_id" => "op-2003",
            "group_id" => "group-93",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 7_000
          })
        ])

      report = report_data("2026-10-05")

      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "ams-central"]

      # ams-plaza has an opening of zero and no movements: omitted.
      assert is_nil(cash_entry(report, "ams-plaza"))
    end

    test "reading reports never changes state" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      first = report_data("2026-10-05")
      _other = report_data("2026-10-03")
      assert report_data("2026-10-05") == first
      assert report_data("2026-10-05") == first

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 5_000
      assert ledger["data"]["cash_held_cents"] == 5_000
    end
  end

  describe "cash movements" do
    setup do
      {_, 200} =
        post_ops([
          open_group_op(),
          destination_op(),
          third_property_op(),
          start_finance_reporting_op()
        ])

      :ok
    end

    test "payments, transfers, reductions, and chargebacks move held cash" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 19_500
          })
        ])

      report = report_data("2026-10-05")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 19_500
      assert entry["closing_held_cents"] == 19_500

      # A transfer has no occurred_on, so it posts on starts_on.
      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      report = report_data("2026-10-03")

      assert movements_of(report, "ams-canal")["transferred_out_cents"] == 4_000
      assert movements_of(report, "ams-plaza")["transferred_in_cents"] == 4_000

      # Transferred-in and transferred-out amounts are equal across all
      # properties on that date.
      total_in =
        report["cash"]
        |> Enum.reduce(0, &(&1["movements"]["transferred_in_cents"] + &2))

      total_out =
        report["cash"]
        |> Enum.reduce(0, &(&1["movements"]["transferred_out_cents"] + &2))

      assert total_in == 4_000
      assert total_out == 4_000

      {_, 200} =
        post_ops([
          reduce_cash_payment_op(%{
            "operation_id" => "op-7001",
            "amount_cents" => 3_000
          })
        ])

      # The reduction drains the newest allocations first: the transferred
      # slice in group-92.
      report = report_data("2026-10-03")
      assert movements_of(report, "ams-plaza")["reduced_cents"] == 3_000

      {_, 200} = post_ops([charge_back_payment_op()])

      report = report_data("2026-10-03")

      # The remaining held cash of op-2001 becomes charged back wherever it
      # is held: 15,500 at the source and 1,000 at the transfer destination.
      assert movements_of(report, "ams-canal")["charged_back_cents"] == 15_500
      assert movements_of(report, "ams-plaza")["charged_back_cents"] == 1_000

      # Nothing remains held anywhere, and the ledger agrees.
      report = report_data("2026-10-05")

      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 0

      # ams-plaza's opening, closing, and every movement on that day are
      # zero, so it is omitted.
      assert is_nil(cash_entry(report, "ams-plaza"))

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 0
      assert ledger["data"]["cash_reduced_cents"] == 3_000
      assert ledger["data"]["cash_charged_back_cents"] == 16_500

      {payment, 200} = get_payment("op-2001")
      assert payment["data"]["held_cents"] == 0
    end

    test "refunds and retentions settle held cash on their occurred_on" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 10_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-11-01"
          })
        ])

      report = report_data("2026-11-01")
      assert movements_of(report, "ams-plaza")["refunded_cents"] == 10_000
      assert cash_entry(report, "ams-plaza")["closing_held_cents"] == 0

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2003",
            "group_id" => "group-93",
            "occurred_on" => "2026-10-06",
            "amount_cents" => 5_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9301",
            "group_id" => "group-93",
            "occurred_on" => "2026-10-07"
          })
        ])

      report = report_data("2026-10-07")
      assert movements_of(report, "ams-central")["retained_cents"] == 5_000
      assert cash_entry(report, "ams-central")["closing_held_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 10_000
      assert ledger["data"]["cash_retained_cents"] == 5_000
    end

    test "converting cash to credit moves held cash to the conversion column" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      report = report_data("2026-10-06")

      assert movements_of(report, "ams-canal")["converted_to_credit_cents"] == 5_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 0

      assert report["credit"]["movements"]["issued_cents"] == 5_500
      assert report["credit"]["closing_liability_cents"] == 5_500

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_converted_to_credit_cents"] == 5_000
      assert ledger["data"]["credit_liability_cents"] == 5_500
    end

    test "reversing a refund reports negative refunded with charged back" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 6_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-06"
          })
        ])

      {_, 200} = post_ops([charge_back_payment_op()])

      report = report_data("2026-10-03")
      ams_plaza = movements_of(report, "ams-plaza")

      assert ams_plaza["refunded_cents"] == -6_000
      assert ams_plaza["charged_back_cents"] == 6_000

      # The reversal cancels out: closing is unchanged by the reclassification.
      report = report_data("2026-10-06")
      assert cash_entry(report, "ams-plaza")["closing_held_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 0
      assert ledger["data"]["cash_charged_back_cents"] == 6_000
    end

    test "the closing balance identity holds for every property" do
      # Every operation posts on starts_on (occurred_on before it), so the
      # day's movements are also the cumulative movements.
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-02",
            "amount_cents" => 19_500
          }),
          cash_payment_op(%{
            "operation_id" => "op-2003",
            "group_id" => "group-93",
            "occurred_on" => "2026-10-02",
            "amount_cents" => 7_000
          })
        ])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      {_, 200} =
        post_ops([
          reduce_cash_payment_op(%{"operation_id" => "op-7001", "amount_cents" => 3_000})
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9301",
            "group_id" => "group-93",
            "occurred_on" => "2026-10-02"
          })
        ])

      report = report_data("2026-10-03")

      for entry <- report["cash"] do
        movements = entry["movements"]

        closing =
          entry["opening_held_cents"] +
            movements["received_cents"] +
            movements["transferred_in_cents"] -
            movements["transferred_out_cents"] -
            movements["refunded_cents"] -
            movements["retained_cents"] -
            movements["converted_to_credit_cents"] -
            movements["reduced_cents"] -
            movements["charged_back_cents"]

        assert closing == entry["closing_held_cents"]
      end

      # The closing positions reconcile to the current ledger views.
      {ledger, 200} = get_ledger()
      total_closing = Enum.reduce(report["cash"], 0, &(&1["closing_held_cents"] + &2))
      assert total_closing == ledger["data"]["cash_held_cents"]
      assert ledger["data"]["cash_held_cents"] == 16_500
    end
  end

  describe "credit movements" do
    setup do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])
      :ok
    end

    test "credit expires on the day after expires_on even without operations" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      # The lot is available through 2027-10-06 and expires 2027-10-07.
      report = report_data("2027-10-06")

      assert report["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert report["credit"]["closing_liability_cents"] == 5_500

      report = report_data("2027-10-07")
      assert report["credit"]["movements"]["expired_cents"] == 5_500
      assert report["credit"]["closing_liability_cents"] == 0

      {ledger, 200} = get_ledger("?on=2027-10-06")
      assert ledger["data"]["credit_liability_cents"] == 5_500

      {ledger, 200} = get_ledger("?on=2027-10-07")
      assert ledger["data"]["credit_liability_cents"] == 0
    end

    test "non-refundable settlement of applied credit is consumed" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      {_, 200} =
        post_ops([
          destination_op(%{
            "operation_id" => "op-1002",
            "rate_plan" => "advance_purchase"
          })
        ])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{
            "operation_id" => "op-5001",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-07",
            "amount_cents" => 5_500
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-08"
          })
        ])

      report = report_data("2026-10-08")
      assert report["credit"]["movements"]["consumed_cents"] == 5_500
      assert report["credit"]["closing_liability_cents"] == 0

      # Applying credit had no movement column: only issued and consumed.
      report = report_data("2026-10-07")

      assert report["credit"]["movements"] == %{
               "issued_cents" => 0,
               "expired_cents" => 0,
               "consumed_cents" => 0,
               "revoked_cents" => 0,
               "absorbed_cents" => 0
             }

      assert report["credit"]["closing_liability_cents"] == 5_500

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 0
    end

    test "applied credit keeps its paused expiry: only the unapplied balance expires" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      {_, 200} =
        post_ops([
          destination_op(%{"operation_id" => "op-1002"})
        ])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{
            "operation_id" => "op-5001",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-07",
            "amount_cents" => 3_000
          })
        ])

      # Only the 2,500 that was never applied expires; the 3,000 applied to
      # the active group keeps its paused expiry and stays in the liability.
      report = report_data("2027-10-07")
      assert report["credit"]["movements"]["expired_cents"] == 2_500
      assert report["credit"]["closing_liability_cents"] == 3_000

      {ledger, 200} = get_ledger("?on=2027-10-07")
      assert ledger["data"]["credit_liability_cents"] == 3_000
    end

    test "cancel_rooms settlements move the selected rooms' held cash" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 9_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_rooms_op(%{
            "operation_id" => "op-6001",
            "occurred_on" => "2026-11-01",
            "room_ids" => ["room-a"]
          })
        ])

      report = report_data("2026-11-01")
      assert movements_of(report, "ams-canal")["refunded_cents"] == 9_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_refunded_cents"] == 9_000
    end

    test "a chargeback revokes the entitlement it funded" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      {_, 200} = post_ops([charge_back_payment_op()])

      report = report_data("2026-10-03")
      assert report["credit"]["movements"]["revoked_cents"] == 5_500

      report = report_data("2026-10-06")
      assert report["credit"]["closing_liability_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 0
      assert ledger["data"]["credit_shortfall_cents"] == 0
    end

    test "a restoration absorbed by shortfall is an absorbed movement" do
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 10_000
          })
        ])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-4001",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      {_, 200} =
        post_ops([
          destination_op(%{"operation_id" => "op-1002"})
        ])

      {_, 200} =
        post_ops([
          apply_hotel_credit_op(%{
            "operation_id" => "op-5001",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-07",
            "amount_cents" => 11_000
          })
        ])

      # The chargeback cannot remove the applied credit: it becomes the
      # lot's unrecovered clawback.
      {_, 200} = post_ops([charge_back_payment_op()])

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_shortfall_cents"] == 11_000

      # Refundable cancellation returns the applied credit to the lot, where
      # the unrecovered clawback absorbs it.
      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-08"
          })
        ])

      report = report_data("2026-10-08")
      assert report["credit"]["movements"]["absorbed_cents"] == 11_000
      assert report["credit"]["closing_liability_cents"] == 0

      {ledger, 200} = get_ledger()
      assert ledger["data"]["credit_liability_cents"] == 0
      assert ledger["data"]["credit_shortfall_cents"] == 0
    end
  end

  describe "posting dates" do
    test "an operation posts on the later of its occurred_on and starts_on" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-09-20",
            "amount_cents" => 5_000
          })
        ])

      # occurred_on is before starts_on: posts on starts_on.
      report = report_data("2026-10-03")
      assert movements_of(report, "ams-canal")["received_cents"] == 5_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 5_000

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-08",
            "amount_cents" => 2_000
          })
        ])

      report = report_data("2026-10-08")
      assert movements_of(report, "ams-canal")["received_cents"] == 2_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 7_000
    end

    test "later submissions can change an earlier open report" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      assert report_data("2026-10-05")["cash"] == []

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      report = report_data("2026-10-05")
      assert movements_of(report, "ams-canal")["received_cents"] == 5_000

      # A later payment backdated before that date changes the same report.
      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-03",
            "amount_cents" => 2_000
          })
        ])

      report = report_data("2026-10-05")
      assert movements_of(report, "ams-canal")["received_cents"] == 5_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 7_000

      report = report_data("2026-10-03")
      assert movements_of(report, "ams-canal")["received_cents"] == 2_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 2_000

      {ledger, 200} = get_ledger()
      assert ledger["data"]["cash_held_cents"] == 7_000
    end

    test "equivalent batches and sequential submissions produce equivalent reports" do
      open = open_group_op()
      start = start_finance_reporting_op()

      pay =
        cash_payment_op(%{
          "operation_id" => "op-2001",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 5_000
        })

      {_, 200} = post_ops([open, start, pay])
      sequential = report_data("2026-10-05")

      # Fresh database state for the batched variant.
      Repo.delete_all(from(m in Movement))
      Repo.delete_all(GroupStay.Groups.Room)
      Repo.delete_all(GroupStay.Groups.Group)
      Repo.delete_all(GroupStay.Operations.Record)
      Repo.delete_all(GroupStay.FinanceReporting.Start)
      Repo.delete_all(GroupStay.FinanceReporting.Position)
      Repo.delete_all(GroupStay.FinanceReporting.LotSeed)
      Repo.delete_all(GroupStay.RoomAccounting.RoomAllocation)

      {_, 200} = post_ops([open, start, pay])
      batched = report_data("2026-10-05")

      assert batched == sequential
    end
  end

  describe "durability and rejections" do
    test "a durable retry does not report a movement twice" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      pay =
        cash_payment_op(%{
          "operation_id" => "op-2001",
          "occurred_on" => "2026-10-05",
          "amount_cents" => 5_000
        })

      {_, 200} = post_ops([pay])

      before = report_data("2026-10-05")

      {_, 200} = post_ops([pay])

      assert report_data("2026-10-05") == before
      assert cash_entry(before, "ams-canal")["closing_held_cents"] == 5_000
    end

    test "rejected operations leave no reporting movement" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      {body, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 50_000
          })
        ])

      assert result(body)["code"] == "payment_exceeds_outstanding"

      report = report_data("2026-10-05")
      assert movements_of(report, "ams-canal")["received_cents"] == 5_000
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 5_000

      # A retried rejection is remembered and still reports nothing.
      {body, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 50_000
          })
        ])

      assert result(body)["code"] == "payment_exceeds_outstanding"

      report = report_data("2026-10-05")
      assert movements_of(report, "ams-canal")["received_cents"] == 5_000
    end

    test "a later rejection keeps earlier movements in the same batch" do
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {body, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          }),
          cash_payment_op(%{
            "operation_id" => "op-2002",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 50_000
          })
        ])

      assert result(body, 0)["status"] == "applied"
      assert result(body, 1)["code"] == "payment_exceeds_outstanding"

      report = report_data("2026-10-05")
      assert movements_of(report, "ams-canal")["received_cents"] == 5_000
    end

    test "movement rows commit with their domain change and are read from storage" do
      # The movement rows are committed with the domain change in one
      # transaction; the report derives purely from stored rows.
      {_, 200} = post_ops([open_group_op(), start_finance_reporting_op()])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 5_000
          })
        ])

      report = report_data("2026-10-05")
      assert cash_entry(report, "ams-canal")["closing_held_cents"] == 5_000
    end
  end

  describe "reports reconcile with existing views" do
    test "cash and credit totals agree with the ledger" do
      {_, 200} =
        post_ops([
          open_group_op(),
          destination_op(),
          start_finance_reporting_op()
        ])

      {_, 200} =
        post_ops([
          cash_payment_op(%{
            "operation_id" => "op-2001",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 19_500
          })
        ])

      {_, 200} = post_ops([transfer_deposit_op(%{"amount_cents" => 4_000})])

      {_, 200} =
        post_ops([
          cancel_op(%{
            "operation_id" => "op-9201",
            "group_id" => "group-92",
            "occurred_on" => "2026-10-06",
            "refund_method" => "hotel_credit"
          })
        ])

      report = report_data("2026-10-10")

      {ledger, 200} = get_ledger()

      total_closing = Enum.reduce(report["cash"], 0, &(&1["closing_held_cents"] + &2))

      assert total_closing == ledger["data"]["cash_held_cents"]
      assert ledger["data"]["cash_held_cents"] == 15_500

      assert report["credit"]["closing_liability_cents"] ==
               ledger["data"]["credit_liability_cents"]

      assert ledger["data"]["credit_liability_cents"] == 4_400
    end
  end
end
