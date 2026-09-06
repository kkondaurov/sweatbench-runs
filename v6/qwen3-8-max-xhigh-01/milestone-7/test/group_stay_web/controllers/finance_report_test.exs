defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Finance
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

  defp open_group_op(overrides \\ %{}) do
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

  defp start_op(overrides \\ %{}) do
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

  defp transfer_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 2000
      },
      overrides
    )
  end

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-08",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp chargeback_op(overrides \\ %{}) do
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

  defp start_reporting(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [start_op(overrides)])
    {conn, result}
  end

  # Gives guest-22 a 6600 hotel-credit lot by refundably cancelling a funded
  # group with hotel credit.
  defp issue_credit(conn, overrides \\ %{}) do
    conn =
      open_group(conn, %{
        "operation_id" => "open-70",
        "group_id" => "group-70",
        "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 10000}]
      })

    conn = pay(conn, "pay-70", "group-70", 6000)

    {conn, [result]} =
      post_batch(conn, [
        cancel_group_op(
          "cancel-70",
          "group-70",
          Map.merge(
            %{"occurred_on" => "2026-10-04", "refund_method" => "hotel_credit"},
            overrides
          )
        )
      ])

    assert result["credit_issued_cents"] == 6600
    conn
  end

  defp get_report(conn, date) do
    conn = get(conn, @report_path, %{"date" => date})
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_ledger(conn, on \\ nil) do
    conn =
      case on do
        nil -> get(conn, @ledger_path)
        date -> get(conn, @ledger_path, %{"on" => date})
      end

    {conn, json_response(conn, 200)["data"]}
  end

  defp cash_entry(report, property_id) do
    Enum.find(report["cash"], &(&1["property_id"] == property_id))
  end

  describe "start_finance_reporting" do
    test "the applied result contains exactly operation_id, status, and starts_on", %{
      conn: conn
    } do
      {conn, result} = start_reporting(conn)

      assert result == %{
               "operation_id" => "op-start",
               "status" => "applied",
               "starts_on" => "2026-10-01"
             }

      conn = get(conn, "/api/v1/operations/op-start")
      assert json_response(conn, 200)["data"] == result
    end

    test "starts with an empty opening position when nothing was committed", %{conn: conn} do
      {conn, result} = start_reporting(conn)
      assert result["status"] == "applied"

      {_conn, report} = get_report(conn, "2026-10-01")
      assert report["cash"] == []
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "the committed financial state becomes the opening position on starts_on", %{
      conn: conn
    } do
      conn = open_group(conn)
      # occurred_on is on starts_on's day and after it; both are opening
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-01"})
      conn = pay(conn, "pay-2", "group-81", 2000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = start_reporting(conn)

      {_conn, report} = get_report(conn, "2026-10-01")
      assert report["date"] == "2026-10-01"
      assert report["status"] == "open"

      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 7000
      assert entry["movements"] == @zero_cash_movements
      assert entry["closing_held_cents"] == 7000
    end

    test "in the same batch, operations before the start are opening and after are movements",
         %{conn: conn} do
      conn = open_group(conn)

      {conn, results} =
        post_batch(conn, [
          payment_op(%{
            "operation_id" => "pay-1",
            "occurred_on" => "2026-10-02",
            "amount_cents" => 3000
          }),
          start_op(),
          payment_op(%{
            "operation_id" => "pay-2",
            "occurred_on" => "2026-10-03",
            "amount_cents" => 2000
          })
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      {conn, first} = get_report(conn, "2026-10-01")
      entry = cash_entry(first, "ams-canal")
      assert entry["opening_held_cents"] == 3000
      assert entry["movements"] == @zero_cash_movements
      assert entry["closing_held_cents"] == 3000

      {_conn, third} = get_report(conn, "2026-10-03")
      entry = cash_entry(third, "ams-canal")
      assert entry["opening_held_cents"] == 3000
      assert entry["movements"]["received_cents"] == 2000
      assert entry["closing_held_cents"] == 5000
    end

    test "in a batch, the first start applies and a later different start is rejected", %{
      conn: conn
    } do
      {_conn, [first, second]} =
        post_batch(conn, [start_op(), start_op(%{"operation_id" => "op-start-2"})])

      assert first["status"] == "applied"

      assert second == %{
               "operation_id" => "op-start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }
    end

    test "a start that loses the singleton race rolls back", %{conn: _conn} do
      {:ok, _} = Repo.transaction(fn -> Finance.start_reporting!(~D[2026-10-01]) end)

      assert {:error, :reporting_start_race} =
               Repo.transaction(fn -> Finance.start_reporting!(~D[2026-11-01]) end)

      assert Finance.start().starts_on == ~D[2026-10-01]
    end

    test "a different start operation is rejected once reporting has started", %{conn: conn} do
      {conn, _} = start_reporting(conn)

      {conn, [result]} =
        post_batch(conn, [
          start_op(%{"operation_id" => "op-start-2", "starts_on" => "2026-11-01"})
        ])

      assert result == %{
               "operation_id" => "op-start-2",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      # the original start date is unchanged
      conn = get(conn, @report_path, %{"date" => "2026-09-30"})
      assert json_response(conn, 404)["error"] == %{"code" => "report_not_available"}

      {_conn, report} = get_report(conn, "2026-10-01")
      assert report["status"] == "open"
    end

    test "a retry of the original start returns the stored result without re-snapshotting", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, first} = start_reporting(conn)
      conn = pay(conn, "pay-2", "group-81", 1000, %{"occurred_on" => "2026-10-06"})

      {conn, [retry]} = post_batch(conn, [start_op()])
      assert retry == first

      {_conn, report} = get_report(conn, "2026-10-06")
      entry = cash_entry(report, "ams-canal")
      # the opening position is still the original snapshot; pay-2 is a movement
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"]["received_cents"] == 1000
      assert entry["closing_held_cents"] == 6000
    end

    test "reusing the start identifier with a different payload conflicts", %{conn: conn} do
      {conn, _} = start_reporting(conn)

      {_conn, [result]} = post_batch(conn, [start_op(%{"starts_on" => "2026-11-01"})])

      assert result == %{
               "operation_id" => "op-start",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }
    end

    test "an invalid or missing starts_on is rejected and does not start reporting", %{
      conn: conn
    } do
      {conn, results} =
        post_batch(conn, [
          start_op(%{"operation_id" => "s-1", "starts_on" => "not-a-date"}),
          start_op(%{"operation_id" => "s-2", "starts_on" => "2026-02-30"}),
          start_op(%{"operation_id" => "s-3"}) |> Map.delete("starts_on"),
          start_op(%{"operation_id" => "s-4", "starts_on" => 20_261_001})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_reporting_date"} = result
      end

      conn = get(conn, @report_path, %{"date" => "2026-10-01"})
      assert json_response(conn, 404)["error"] == %{"code" => "report_not_available"}

      # a valid start can still follow
      {conn, result} = start_reporting(conn, %{"operation_id" => "s-5"})
      assert result["status"] == "applied"

      {_conn, report} = get_report(conn, "2026-10-01")
      assert report["status"] == "open"
    end

    test "does not address a group and increments no revision", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["revision"] == 1
    end

    test "a missing occurred_on is an invalid operation", %{conn: conn} do
      {_conn, [result]} = post_batch(conn, [start_op() |> Map.delete("occurred_on")])
      assert %{"status" => "rejected", "code" => "invalid_operation"} = result
    end
  end

  describe "daily report availability" do
    test "a missing or invalid date returns 422 invalid_reporting_date", %{conn: conn} do
      conn = get(conn, @report_path)
      assert json_response(conn, 422)["error"] == %{"code" => "invalid_reporting_date"}

      conn = get(conn, @report_path, %{"date" => "yesterday"})
      assert json_response(conn, 422)["error"] == %{"code" => "invalid_reporting_date"}

      conn = get(conn, @report_path, %{"date" => "2026-13-01"})
      assert json_response(conn, 422)["error"] == %{"code" => "invalid_reporting_date"}
    end

    test "before reporting has started the report is not available", %{conn: conn} do
      conn = get(conn, @report_path, %{"date" => "2026-10-01"})
      assert json_response(conn, 404)["error"] == %{"code" => "report_not_available"}
    end

    test "a date before starts_on is not available", %{conn: conn} do
      {conn, _} = start_reporting(conn)

      conn = get(conn, @report_path, %{"date" => "2026-09-30"})
      assert json_response(conn, 404)["error"] == %{"code" => "report_not_available"}

      {_conn, report} = get_report(conn, "2026-10-01")
      assert report["status"] == "open"
    end

    test "an invalid date is rejected even before reporting has started", %{conn: conn} do
      conn = get(conn, @report_path, %{"date" => "bogus"})
      assert json_response(conn, 422)["error"] == %{"code" => "invalid_reporting_date"}
    end
  end

  describe "reading one day" do
    test "an empty day reports no cash entries and zero credit", %{conn: conn} do
      {conn, _} = start_reporting(conn)

      {_conn, report} = get_report(conn, "2026-10-01")

      assert report == %{
               "date" => "2026-10-01",
               "status" => "open",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => @zero_credit_movements,
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => @no_late_adjustments
             }
    end

    test "cash entries have exactly the documented shape", %{conn: conn} do
      conn = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-04"})
      conn = pay(conn, "pay-2", "group-81", 500, %{"occurred_on" => "2026-10-05"})

      {_conn, report} = get_report(conn, "2026-10-05")

      assert report["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5000,
                 "movements" => %{@zero_cash_movements | "received_cents" => 500},
                 "closing_held_cents" => 5500
               }
             ]
    end

    test "a property is omitted only when opening, closing, and every movement are zero", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = open_second_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      {conn, _} = start_reporting(conn)

      {conn, report} = get_report(conn, "2026-10-01")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal"]

      # a day on which the empty property sees a transfer in and out is shown
      conn = pay(conn, "pay-2", "group-92", 1000, %{"occurred_on" => "2026-10-06"})

      {_conn, report} = get_report(conn, "2026-10-06")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "ber-mitte"]
    end

    test "cash is ordered by property_id", %{conn: conn} do
      conn = open_group(conn, %{"property_id" => "ber-mitte"})
      conn = open_second_group(conn, %{"property_id" => "ams-canal"})
      conn = pay(conn, "pay-1", "group-81", 1000)
      conn = pay(conn, "pay-2", "group-92", 2000)
      {conn, _} = start_reporting(conn)

      {_conn, report} = get_report(conn, "2026-10-01")
      assert Enum.map(report["cash"], & &1["property_id"]) == ["ams-canal", "ber-mitte"]
    end
  end

  describe "cash movements" do
    test "a payment posts received where the group belongs", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, report} = get_report(conn, "2026-10-04")
      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 5000

      # the next day carries the balance forward without movements
      {_conn, next} = get_report(conn, "2026-10-05")
      entry = cash_entry(next, "ams-canal")
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"] == @zero_cash_movements
      assert entry["closing_held_cents"] == 5000
    end

    test "a refundable cancellation posts refunded", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-10-07"})
        ])

      assert cancel["refunded_cents"] == 5000

      {_conn, report} = get_report(conn, "2026-10-07")
      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 5000
      assert entry["movements"]["refunded_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end

    test "a non-refundable cancellation posts retained", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-12-01"})
        ])

      assert cancel["retained_cents"] == 5000

      {_conn, report} = get_report(conn, "2026-12-01")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["retained_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end

    test "a hotel-credit settlement posts converted cash and issued liability", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})

      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-07",
            "refund_method" => "hotel_credit"
          })
        ])

      assert cancel["credit_issued_cents"] == 6600

      {_conn, report} = get_report(conn, "2026-10-07")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["converted_to_credit_cents"] == 6000
      assert entry["closing_held_cents"] == 0

      assert report["credit"] == %{
               "opening_liability_cents" => 0,
               "movements" => %{@zero_credit_movements | "issued_cents" => 6600},
               "closing_liability_cents" => 6600
             }
    end

    test "cancelling selected rooms posts movements only for the settled rooms", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [result]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-rooms",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-07",
            "group_id" => "group-81",
            "room_ids" => ["room-a"]
          }
        ])

      assert result["refunded_cents"] == 5000

      {_conn, report} = get_report(conn, "2026-10-07")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["refunded_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end

    test "transfers post matching out and in movements on the two properties", %{conn: conn} do
      conn = open_group(conn)
      conn = open_second_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [transfer]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])
      assert transfer["status"] == "applied"

      {_conn, report} = get_report(conn, "2026-10-06")

      source = cash_entry(report, "ams-canal")
      assert source["movements"]["transferred_out_cents"] == 2000
      assert source["closing_held_cents"] == 3000

      destination = cash_entry(report, "ber-mitte")
      assert destination["opening_held_cents"] == 0
      assert destination["movements"]["transferred_in_cents"] == 2000
      assert destination["closing_held_cents"] == 2000
    end

    test "a reduction follows held cash to the property where it is held", %{conn: conn} do
      conn = open_group(conn)
      conn = open_second_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])

      {conn, [reduction]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})])

      assert reduction["status"] == "applied"

      {_conn, report} = get_report(conn, "2026-10-08")

      # the transferred units were held at the destination, so the correction
      # is reported there, not at the payment's original property
      destination = cash_entry(report, "ber-mitte")
      assert destination["movements"]["reduced_cents"] == 2000
      assert destination["closing_held_cents"] == 0

      source = cash_entry(report, "ams-canal")
      assert source["movements"]["reduced_cents"] == 0
      assert source["closing_held_cents"] == 3000
    end

    test "a chargeback of held cash posts charged_back where the cash is held", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [chargeback]} = post_batch(conn, [chargeback_op()])
      assert chargeback["charged_back_cents"] == 5000

      {_conn, report} = get_report(conn, "2026-10-09")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["charged_back_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end

    test "reversing an earlier refund reports negative refunded with positive charged_back", %{
      conn: conn
    } do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-03"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-10-07"})
        ])

      {conn, refunded_report} = get_report(conn, "2026-10-07")
      assert cash_entry(refunded_report, "ams-canal")["movements"]["refunded_cents"] == 5000

      {conn, [chargeback]} = post_batch(conn, [chargeback_op()])
      assert chargeback["charged_back_cents"] == 5000

      {_conn, report} = get_report(conn, "2026-10-09")
      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["refunded_cents"] == -5000
      assert entry["movements"]["charged_back_cents"] == 5000
      assert entry["closing_held_cents"] == 0
    end
  end

  describe "posting dates" do
    test "an operation with occurred_on before starts_on posts on starts_on", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-05"})
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-02"})

      # dates before starts_on remain unavailable
      conn = get(conn, @report_path, %{"date" => "2026-10-04"})
      assert json_response(conn, 404)["error"] == %{"code" => "report_not_available"}

      {_conn, report} = get_report(conn, "2026-10-05")
      entry = cash_entry(report, "ams-canal")
      assert entry["opening_held_cents"] == 0
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 5000
    end

    test "later submissions can change an earlier open report", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)

      {conn, before} = get_report(conn, "2026-10-04")
      assert cash_entry(before, "ams-canal") == nil

      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})

      {_conn, after_submission} = get_report(conn, "2026-10-04")
      entry = cash_entry(after_submission, "ams-canal")
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 5000
    end

    test "rejected operations leave no reporting movement", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 19500, %{"occurred_on" => "2026-10-04"})

      {conn, [rejected]} =
        post_batch(conn, [
          payment_op(%{
            "operation_id" => "pay-2",
            "occurred_on" => "2026-10-05",
            "amount_cents" => 1
          })
        ])

      assert rejected["code"] == "payment_exceeds_outstanding"

      {_conn, report} = get_report(conn, "2026-10-05")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 0
      assert entry["closing_held_cents"] == 19500
    end

    test "a later rejected operation in a batch keeps earlier applied movements", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)

      {conn, results} =
        post_batch(conn, [
          payment_op(%{"operation_id" => "pay-1", "amount_cents" => 19500}),
          payment_op(%{"operation_id" => "pay-2", "amount_cents" => 1})
        ])

      assert Enum.at(results, 0)["status"] == "applied"
      assert Enum.at(results, 1)["status"] == "rejected"

      {_conn, report} = get_report(conn, "2026-10-04")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 19500
      assert entry["closing_held_cents"] == 19500
    end

    test "a durable retry does not report a movement twice", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, report} = get_report(conn, "2026-10-04")
      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["received_cents"] == 5000
      assert entry["closing_held_cents"] == 5000
    end
  end

  describe "credit movements" do
    test "applying and restoring credit reports no movement and changes no liability", %{
      conn: conn
    } do
      conn = issue_credit(conn)
      conn = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 3000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-05"})

      {conn, report} = get_report(conn, "2026-10-05")
      assert report["credit"]["opening_liability_cents"] == 6600
      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["closing_liability_cents"] == 6600

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-10-07"})
        ])

      {_conn, restored} = get_report(conn, "2026-10-07")
      assert restored["credit"]["movements"] == @zero_credit_movements
      assert restored["credit"]["closing_liability_cents"] == 6600
    end

    test "transferring applied credit reports no movement", %{conn: conn} do
      conn = issue_credit(conn)
      conn = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 3000, %{"occurred_on" => "2026-10-04"})
      conn = open_second_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-05"})

      {conn, [transfer]} = post_batch(conn, [transfer_op(%{"amount_cents" => 3000})])
      assert transfer["status"] == "applied"

      {_conn, report} = get_report(conn, "2026-10-06")
      assert report["cash"] == []
      assert report["credit"]["movements"] == @zero_credit_movements
      assert report["credit"]["closing_liability_cents"] == 6600
    end

    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      conn = issue_credit(conn)
      conn = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 3000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-10-05"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-12-01"})
        ])

      {_conn, report} = get_report(conn, "2026-12-01")
      assert report["credit"]["movements"]["consumed_cents"] == 3000
      assert report["credit"]["closing_liability_cents"] == 3600
    end

    test "credit expires on its expiry date even without an operation that day", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})

      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      assert cancel["credit_issued_cents"] == 6600

      # the lot is available through 2027-10-04 and expires on 2027-10-05
      {conn, before} = get_report(conn, "2027-10-04")
      assert before["credit"]["closing_liability_cents"] == 6600
      assert before["credit"]["movements"]["expired_cents"] == 0

      {_conn, report} = get_report(conn, "2027-10-05")
      assert report["credit"]["opening_liability_cents"] == 6600
      assert report["credit"]["movements"]["expired_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "an opening lot's expiry is reported within the window", %{conn: conn} do
      conn = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 6000)

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-11-01"})

      {conn, opening} = get_report(conn, "2026-11-01")
      assert opening["credit"]["opening_liability_cents"] == 6600

      {_conn, report} = get_report(conn, "2027-10-05")
      assert report["credit"]["movements"]["expired_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "a lot already expired on starts_on is part of neither opening nor movements", %{
      conn: conn
    } do
      conn = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 6000)

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2025-10-01",
            "refund_method" => "hotel_credit"
          })
        ])

      # the lot expired on 2026-10-02, before starts_on
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-11-01"})

      {_conn, report} = get_report(conn, "2026-11-01")
      assert report["credit"]["opening_liability_cents"] == 0
      assert report["credit"]["movements"] == @zero_credit_movements
    end

    test "a lot issued after the start but already expired on starts_on nets to nothing", %{
      conn: conn
    } do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn, %{"starts_on" => "2026-11-01"})
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-11-02"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2025-10-01",
            "refund_method" => "hotel_credit"
          })
        ])

      # the lot's expiry predates starts_on, so its issuance and expiry both
      # post on starts_on and the liability equation still holds
      {_conn, report} = get_report(conn, "2026-11-01")
      assert report["credit"]["movements"]["issued_cents"] == 6600
      assert report["credit"]["movements"]["expired_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 0
    end

    test "a chargeback revokes the issued entitlement", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      {conn, [chargeback]} = post_batch(conn, [chargeback_op()])
      assert chargeback["charged_back_cents"] == 6000

      {conn, issued_report} = get_report(conn, "2026-10-04")
      assert issued_report["credit"]["movements"]["issued_cents"] == 6600

      {_conn, report} = get_report(conn, "2026-10-09")

      assert report["credit"]["opening_liability_cents"] == 6600
      assert report["credit"]["movements"]["revoked_cents"] == 6600
      assert report["credit"]["closing_liability_cents"] == 0

      entry = cash_entry(report, "ams-canal")
      assert entry["movements"]["converted_to_credit_cents"] == -6000
      assert entry["movements"]["charged_back_cents"] == 6000
      assert entry["closing_held_cents"] == 0
    end

    test "restoration absorbed by a shortfall reports absorbed", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      conn = open_second_group(conn)
      conn = apply_credit(conn, "apply-1", "group-92", 5000, %{"occurred_on" => "2026-10-05"})

      {conn, [_]} = post_batch(conn, [chargeback_op(%{"occurred_on" => "2026-10-06"})])

      {conn, report} = get_report(conn, "2026-10-06")
      assert report["credit"]["movements"]["revoked_cents"] == 1600
      assert report["credit"]["closing_liability_cents"] == 5000

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"occurred_on" => "2026-10-07"})
        ])

      {_conn, report} = get_report(conn, "2026-10-07")
      assert report["credit"]["movements"]["absorbed_cents"] == 5000
      assert report["credit"]["closing_liability_cents"] == 0
    end
  end

  describe "reconciliation" do
    test "cash movements across reports reconcile to the ledger", %{conn: conn} do
      conn = open_group(conn)
      conn = open_second_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000, %{"occurred_on" => "2026-10-04"})
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-2", "group-81", 7000, %{"occurred_on" => "2026-10-06"})

      {conn, [_]} =
        post_batch(conn, [transfer_op(%{"occurred_on" => "2026-10-07", "amount_cents" => 4000})])

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"occurred_on" => "2026-10-08"})
        ])

      conn = pay(conn, "pay-3", "group-81", 2000, %{"occurred_on" => "2026-10-09"})

      {conn, [_]} =
        post_batch(conn, [
          reduce_op(%{
            "payment_operation_id" => "pay-2",
            "amount_cents" => 1000,
            "occurred_on" => "2026-10-10"
          })
        ])

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{"occurred_on" => "2026-12-01"})
        ])

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 4000
      assert ledger["cash_retained_cents"] == 9000
      assert ledger["cash_reduced_cents"] == 1000

      totals =
        Enum.reduce(
          ~w(2026-10-04 2026-10-06 2026-10-07 2026-10-08 2026-10-09 2026-10-10 2026-12-01),
          %{},
          fn date, acc ->
            {_conn, report} = get_report(conn, date)

            Enum.reduce(report["cash"], acc, fn entry, acc ->
              Enum.reduce(entry["movements"], acc, fn {kind, amount}, acc ->
                Map.update(acc, kind, amount, &(&1 + amount))
              end)
            end)
          end
        )

      # pay-1 was committed before the start and is part of the opening
      # position, not a movement
      assert totals["received_cents"] == 9000
      assert totals["transferred_out_cents"] == 4000
      assert totals["transferred_in_cents"] == 4000
      assert totals["refunded_cents"] == 4000
      assert totals["reduced_cents"] == 1000
      assert totals["retained_cents"] == 9000

      {_conn, final} = get_report(conn, "2026-12-01")

      closing =
        final["cash"]
        |> Enum.map(& &1["closing_held_cents"])
        |> Enum.sum()

      assert closing == ledger["cash_held_cents"]
    end

    test "credit movements reconcile to the ledger liability", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 6000, %{"occurred_on" => "2026-10-04"})

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-81", "group-81", %{
            "occurred_on" => "2026-10-04",
            "refund_method" => "hotel_credit"
          })
        ])

      conn = open_second_group(conn)
      conn = apply_credit(conn, "apply-1", "group-92", 5000, %{"occurred_on" => "2026-10-05"})
      {conn, [_]} = post_batch(conn, [chargeback_op(%{"occurred_on" => "2026-10-06"})])

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"occurred_on" => "2026-10-07"})
        ])

      {conn, ledger} = get_ledger(conn, "2026-10-07")
      assert ledger["credit_liability_cents"] == 0

      # the report reconstructs the liability as it was on each day
      {conn, third} = get_report(conn, "2026-10-05")
      assert third["credit"]["closing_liability_cents"] == 6600

      {conn, fourth} = get_report(conn, "2026-10-06")
      assert fourth["credit"]["closing_liability_cents"] == 5000

      {_conn, final} = get_report(conn, "2026-10-07")

      # on the latest day the report reconciles with the current view
      assert final["credit"]["closing_liability_cents"] == ledger["credit_liability_cents"]

      assert final["credit"] == %{
               "opening_liability_cents" => 5000,
               "movements" => %{@zero_credit_movements | "absorbed_cents" => 5000},
               "closing_liability_cents" => 0
             }
    end

    test "reading reports never changes them or any domain state", %{conn: conn} do
      conn = open_group(conn)
      {conn, _} = start_reporting(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {conn, first_read} = get_report(conn, "2026-10-04")
      {conn, ledger_before} = get_ledger(conn)
      {conn, _other_day} = get_report(conn, "2026-10-01")
      {conn, second_read} = get_report(conn, "2026-10-04")
      {_conn, ledger_after} = get_ledger(conn)

      assert first_read == second_read
      assert ledger_before == ledger_after
    end

    test "a batch submission produces the expected reports", %{conn: conn} do
      {conn, results} =
        post_batch(conn, [
          open_group_op(),
          payment_op(%{
            "operation_id" => "pay-1",
            "occurred_on" => "2026-10-02",
            "amount_cents" => 5000
          }),
          start_op(),
          payment_op(%{
            "operation_id" => "pay-2",
            "occurred_on" => "2026-10-03",
            "amount_cents" => 2000
          })
        ])

      assert Enum.all?(results, &(&1["status"] == "applied"))

      {_conn, report} = get_report(conn, "2026-10-03")
      assert report == equivalence_report()
    end

    test "sequential submissions produce the same reports as the equivalent batch", %{
      conn: conn
    } do
      conn =
        Enum.reduce(
          [
            open_group_op(),
            payment_op(%{
              "operation_id" => "pay-1",
              "occurred_on" => "2026-10-02",
              "amount_cents" => 5000
            }),
            start_op(),
            payment_op(%{
              "operation_id" => "pay-2",
              "occurred_on" => "2026-10-03",
              "amount_cents" => 2000
            })
          ],
          conn,
          fn operation, conn ->
            {conn, [result]} = post_batch(conn, [operation])
            assert result["status"] == "applied"
            conn
          end
        )

      {_conn, report} = get_report(conn, "2026-10-03")
      assert report == equivalence_report()
    end
  end

  defp equivalence_report do
    %{
      "date" => "2026-10-03",
      "status" => "open",
      "cash" => [
        %{
          "property_id" => "ams-canal",
          "opening_held_cents" => 5000,
          "movements" => %{@zero_cash_movements | "received_cents" => 2000},
          "closing_held_cents" => 7000
        }
      ],
      "credit" => %{
        "opening_liability_cents" => 0,
        "movements" => @zero_credit_movements,
        "closing_liability_cents" => 0
      },
      "late_adjustments" => @no_late_adjustments
    }
  end
end
