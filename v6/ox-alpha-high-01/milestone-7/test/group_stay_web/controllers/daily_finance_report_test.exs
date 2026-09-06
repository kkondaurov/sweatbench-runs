defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  @moduletag :capture_log

  # The default group has rooms room-a (deposit 9_000) and room-b (deposit
  # 10_500) at ams-canal, 19_500 in total. The companion group has one room
  # room-c (deposit 6_000) at lon-thames. Both belong to guest-22.

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

  describe "starting finance reporting" do
    test "the applied result contains exactly the three documented fields", %{conn: conn} do
      assert [result] = run_batch(conn, [start_op("op-fin", "2026-11-01")])

      assert result == %{
               "operation_id" => "op-fin",
               "status" => "applied",
               "starts_on" => "2026-11-01"
             }
    end

    test "a retry of the original start replays its stored result", %{conn: conn} do
      assert [first] = run_batch(conn, [start_op("op-fin", "2026-11-01")])
      assert [replay] = run_batch(conn, [start_op("op-fin", "2026-11-01")])
      assert replay == first

      # A different payload under the same identifier is still a conflict.
      assert [%{"code" => "operation_id_conflict"}] =
               run_batch(conn, [start_op("op-fin", "2026-11-02")])
    end

    test "a different start operation after reporting began is rejected", %{conn: conn} do
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "reporting_already_started"} = rejection] =
               run_batch(conn, [start_op("op-fin-2", "2026-11-15")])

      assert rejection["operation_id"] == "op-fin-2"
      refute Map.has_key?(rejection, "starts_on")
    end

    test "an invalid or missing starts_on is rejected as invalid_reporting_date", %{conn: conn} do
      results =
        run_batch(conn, [
          start_op("op-bad", "not-a-date"),
          start_op("op-missing", "2026-11-01") |> Map.delete("starts_on")
        ])

      assert Enum.all?(results, &(&1["code"] == "invalid_reporting_date"))

      # Nothing was started, so reporting can still begin.
      assert [%{"status" => "applied"}] = run_batch(conn, [start_op("op-good", "2026-11-01")])
    end
  end

  describe "reading one day" do
    test "missing or invalid dates return 422 as invalid_reporting_date", %{conn: conn} do
      for query <- ["", "?date=nonsense", "?date=2026-13-40"] do
        conn = get_report(conn, query)

        assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}
      end
    end

    test "before reporting started, and before starts_on, the report is unavailable", %{
      conn: conn
    } do
      conn
      |> get_report("?date=2026-11-01")
      |> json_response(404)
      |> then(&assert(&1 == %{"error" => %{"code" => "report_not_available"}}))

      open_default_group(conn)
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      assert conn
             |> get_report("?date=2026-10-31")
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      assert %{"data" => _} =
               conn |> get_report("?date=2026-11-01") |> json_response(200)
    end

    test "the financial state before the start operation becomes the opening position", %{
      conn: conn
    } do
      open_default_group(conn)

      # Committed well before reporting starts, with an occurred_on that is
      # itself before starts_on.
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      assert %{"data" => report} =
               conn |> get_report("?date=2026-11-01") |> json_response(200)

      assert report == %{
               "date" => "2026-11-01",
               "status" => "open",
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "opening_held_cents" => 12_000,
                   "movements" => @zero_cash_movements,
                   "closing_held_cents" => 12_000
                 }
               ],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => @zero_credit_movements,
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => %{"cash" => [], "credit" => @zero_credit_movements}
             }
    end

    test "in the same batch, operations before the start are opening position and operations after it are movements",
         %{conn: conn} do
      open_default_group(conn)

      results =
        run_batch(conn, [
          payment_operation("op-pay-before", 6_000),
          start_op("op-fin", "2026-11-01"),
          payment_operation("op-pay-after", 5_000) |> Map.put("occurred_on", "2026-11-04")
        ])

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied)

      assert %{"data" => %{"cash" => [%{"opening_held_cents" => 6_000, "movements" => mov}]}} =
               conn |> get_report("?date=2026-11-01") |> json_response(200)

      assert mov["received_cents"] == 0

      assert %{"data" => %{"cash" => [%{"movements" => mov4, "closing_held_cents" => 11_000}]}} =
               conn |> get_report("?date=2026-11-04") |> json_response(200)

      assert mov4["received_cents"] == 5_000
    end

    test "an operation's posting date is the later of occurred_on and starts_on", %{conn: conn} do
      open_default_group(conn)
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      # Submitted after reporting started, but dated before starts_on.
      run_batch(conn, [
        payment_operation("op-pay-late-submission", 3_000)
        |> Map.put("occurred_on", "2026-10-20")
      ])

      assert %{"data" => %{"cash" => [%{"movements" => mov, "closing_held_cents" => 3_000}]}} =
               conn |> get_report("?date=2026-11-01") |> json_response(200)

      assert mov["received_cents"] == 3_000
    end

    test "later submissions change an earlier open report", %{conn: conn} do
      open_default_group(conn)
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      before =
        conn |> get_report("?date=2026-11-05") |> json_response(200) |> Map.fetch!("data")

      run_batch(conn, [
        payment_operation("op-pay", 2_000) |> Map.put("occurred_on", "2026-11-05")
      ])

      after_submission =
        conn |> get_report("?date=2026-11-05") |> json_response(200) |> Map.fetch!("data")

      refute before == after_submission

      assert after_submission["cash"]
             |> hd()
             |> Map.fetch!("movements")
             |> Map.fetch!("received_cents") ==
               2_000
    end

    test "reading reports repeatedly and in any order never changes them or domain state", %{
      conn: conn
    } do
      open_default_group(conn)
      run_batch(conn, [payment_operation("op-pay", 9_000)])
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      later =
        conn |> get_report("?date=2026-11-02") |> json_response(200) |> Map.fetch!("data")

      earlier =
        conn |> get_report("?date=2026-11-01") |> json_response(200) |> Map.fetch!("data")

      again = conn |> get_report("?date=2026-11-02") |> json_response(200) |> Map.fetch!("data")

      assert again == later
      assert group_json(conn)["revision"] == 2
      assert ledger_json(conn)["cash_held_cents"] == 9_000
      assert earlier["cash"] == later["cash"]
    end

    test "rejected operations leave no reporting movement", %{conn: conn} do
      open_default_group(conn)
      run_batch(conn, [start_op("op-fin", "2026-11-01")])

      run_batch(conn, [
        payment_operation("op-too-big", 99_000) |> Map.put("occurred_on", "2026-11-02"),
        %{
          "operation_id" => "op-unknown-group",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-11-02",
          "group_id" => "ghost",
          "amount_cents" => 100
        }
      ])

      assert %{"data" => %{"cash" => []}} =
               conn |> get_report("?date=2026-11-02") |> json_response(200)
    end
  end

  describe "cash movements" do
    setup :started_default_group

    test "a refundable cash cancellation refunds where the cash was settled", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81"
        }
      ])

      assert %{"data" => %{"cash" => [entry]}} =
               conn |> get_report("?date=2026-11-20") |> json_response(200)

      assert entry["property_id"] == "ams-canal"
      assert entry["opening_held_cents"] == 12_000
      assert entry["movements"]["refunded_cents"] == 12_000
      assert entry["closing_held_cents"] == 0

      assert ledger_json(conn)["cash_refunded_cents"] == 12_000
      assert ledger_json(conn)["cash_held_cents"] == 0
    end

    test "a non-refundable cancellation retains the cash", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-81"
        }
      ])

      assert %{"data" => %{"cash" => [%{"movements" => mov, "closing_held_cents" => 0}]}} =
               conn |> get_report("?date=2026-12-01") |> json_response(200)

      assert mov["retained_cents"] == 12_000
      assert mov["refunded_cents"] == 0
    end

    test "transfers move between the groups' properties and balance company-wide", %{conn: conn} do
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [
        transfer_op("op-xfer", "group-81", "group-92", 5_000, "2026-11-05")
      ])

      assert %{"data" => %{"cash" => [ams, lon]}} =
               conn |> get_report("?date=2026-11-05") |> json_response(200)

      assert ams["property_id"] == "ams-canal"
      assert ams["movements"]["transferred_out_cents"] == 5_000
      assert ams["closing_held_cents"] == 7_000

      assert lon["property_id"] == "lon-thames"
      assert lon["movements"]["transferred_in_cents"] == 5_000
      assert lon["closing_held_cents"] == 5_000
    end

    test "a reduction follows the affected cash to the holding property", %{conn: conn} do
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])
      run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 5_000, "2026-11-05")])

      run_batch(conn, [
        reduce_op("op-reduce", "op-pay", 4_000, "2026-11-08")
      ])

      assert %{"data" => %{"cash" => [ams, lon]}} =
               conn |> get_report("?date=2026-11-08") |> json_response(200)

      # The most recent allocations were transferred, so the reduction comes
      # out of lon-thames where the cash is now held.
      assert ams["movements"]["reduced_cents"] == 0
      assert lon["opening_held_cents"] == 5_000
      assert lon["movements"]["reduced_cents"] == 4_000
      assert lon["closing_held_cents"] == 1_000

      assert ledger_json(conn)["cash_reduced_cents"] == 4_000
    end

    test "charging back an earlier refund reverses it and records the chargeback", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81"
        },
        charge_back_op("op-chb", "op-pay", "2026-11-25")
      ])

      assert %{"data" => %{"cash" => [entry]}} =
               conn |> get_report("?date=2026-11-25") |> json_response(200)

      assert entry["property_id"] == "ams-canal"
      assert entry["movements"]["refunded_cents"] == -12_000
      assert entry["movements"]["charged_back_cents"] == 12_000
      assert entry["closing_held_cents"] == 0

      assert ledger_json(conn)["cash_charged_back_cents"] == 12_000
      assert ledger_json(conn)["cash_refunded_cents"] == 0
    end

    test "payment-addressed operations without occurred_on post on starts_on", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-reduce",
                   "type" => "reduce_cash_payment",
                   "payment_operation_id" => "op-pay",
                   "amount_cents" => 4_000
                 }
               ])

      assert %{
               "data" => %{
                 "cash" => [entry],
                 "credit" => %{"movements" => @zero_credit_movements}
               }
             } =
               conn |> get_report("?date=#{starts_on()}") |> json_response(200)

      assert entry["movements"]["reduced_cents"] == 4_000
      assert entry["closing_held_cents"] == 8_000

      # Nothing moved on other dates; the carried-forward balance still shows.
      assert %{"data" => %{"cash" => [later_entry]}} =
               conn |> get_report("?date=2026-12-01") |> json_response(200)

      assert later_entry["movements"] == @zero_cash_movements
      assert later_entry["closing_held_cents"] == 8_000
    end

    test "charging back converted cash revokes the entitlement it created", %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "refund_method" => "hotel_credit"
        },
        charge_back_op("op-chb", "op-pay", "2026-11-25")
      ])

      assert %{"data" => %{"cash" => [entry], "credit" => credit}} =
               conn |> get_report("?date=2026-11-25") |> json_response(200)

      # The converted principal reverses its classification and joins the
      # chargeback; the unspent entitlement is revoked from the lot.
      assert entry["movements"]["converted_to_credit_cents"] == -12_000
      assert entry["movements"]["charged_back_cents"] == 12_000
      assert entry["closing_held_cents"] == 0

      assert credit["movements"]["revoked_cents"] == 13_200
      assert credit["closing_liability_cents"] == 0

      assert ledger_json(conn)["credit_liability_cents"] == 0
    end

    test "reports reconcile with the ledger views", %{conn: conn} do
      open_companion_group(conn)
      run_batch(conn, [payment_operation("op-pay", 12_000)])
      run_batch(conn, [transfer_op("op-xfer", "group-81", "group-92", 5_000, "2026-11-05")])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-92"
        }
      ])

      # Walking every open report from starts_on must end where the ledger is.
      {_, held, refunded} =
        Enum.reduce(Date.range(~D[2026-11-01], ~D[2026-11-20]), {nil, 0, 0}, fn date,
                                                                                {_, _previous,
                                                                                 refunded} ->
          %{"data" => %{"cash" => entries}} =
            conn |> get_report("?date=#{Date.to_iso8601(date)}") |> json_response(200)

          held = Enum.sum(Enum.map(entries, & &1["closing_held_cents"]))

          refunded =
            refunded +
              Enum.sum(Enum.map(entries, & &1["movements"]["refunded_cents"]))

          {date, held, refunded}
        end)

      assert held == ledger_json(conn)["cash_held_cents"]
      assert refunded == ledger_json(conn)["cash_refunded_cents"]
    end

    test "properties whose balances and movements are zero are omitted", %{conn: conn} do
      open_companion_group(conn)

      assert %{"data" => %{"cash" => []}} =
               conn |> get_report("?date=#{starts_on()}") |> json_response(200)
    end
  end

  describe "credit movements" do
    setup :started_default_group

    test "converting settled cash issues credit and its unused remainder expires on the following day",
         %{conn: conn} do
      run_batch(conn, [payment_operation("op-pay", 12_000)])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-11-20",
          "group_id" => "group-81",
          "refund_method" => "hotel_credit"
        }
      ])

      # The conversion moved the cash out through `converted_to_credit` and
      # issued 110% of it as credit liability.
      assert %{"data" => %{"cash" => [entry], "credit" => credit}} =
               conn |> get_report("?date=2026-11-20") |> json_response(200)

      assert entry["movements"]["converted_to_credit_cents"] == 12_000
      assert credit["movements"]["issued_cents"] == 13_200
      assert credit["closing_liability_cents"] == 13_200

      # The lot expires on 2027-11-21 and expires on the following date, even
      # though no partner operation was submitted that day.
      assert %{"data" => report} =
               conn |> get_report("?date=2027-11-22") |> json_response(200)

      assert report["credit"]["movements"]["expired_cents"] == 13_200
      assert report["credit"]["closing_liability_cents"] == 0

      assert %{"data" => %{"credit" => %{"movements" => quiet_moves}}} =
               conn |> get_report("?date=2027-11-23") |> json_response(200)

      assert quiet_moves["expired_cents"] == 0
    end

    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      mint_credit_for_guest(conn)

      run_batch(conn, [
        apply_credit_op("op-apply", 4_000, "2026-11-05")
      ])

      run_batch(conn, [
        %{
          "operation_id" => "op-cancel",
          "type" => "cancel_group",
          "occurred_on" => "2026-12-01",
          "group_id" => "group-81"
        }
      ])

      assert %{"data" => %{"credit" => %{"movements" => moves}}} =
               conn |> get_report("?date=2026-12-01") |> json_response(200)

      assert moves["consumed_cents"] == 4_000

      # The remaining lot liability is untouched until it expires.
      assert %{"data" => %{"credit" => %{"closing_liability_cents" => 7_000}}} =
               conn |> get_report("?date=2026-12-01") |> json_response(200)
    end

    test "applying credit changes no movement column", %{conn: conn} do
      mint_credit_for_guest(conn)

      run_batch(conn, [apply_credit_op("op-apply", 4_000, "2026-11-05")])

      # Reading a date after the credit was issued: applying it moved liability
      # between available and applied, which is no movement at all.
      assert %{"data" => %{"credit" => %{"movements" => moves}}} =
               conn |> get_report("?date=2026-11-20") |> json_response(200)

      assert moves == @zero_credit_movements

      assert ledger_json(conn)["credit_liability_cents"] == 11_000
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp starts_on, do: "2026-11-01"

  defp started_default_group(%{conn: conn}) do
    open_default_group(conn)
    run_batch(conn, [start_op("op-fin", starts_on())])
    %{conn: conn}
  end

  defp open_default_group(conn), do: open_group(conn, %{})

  defp open_companion_group(conn) do
    open_group(conn, %{
      "operation_id" => "op-open-b",
      "group_id" => "group-92",
      "property_id" => "lon-thames",
      "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 10_000}]
    })
  end

  defp open_group(conn, overrides) do
    assert [%{"status" => "applied"}] =
             run_batch(conn, [Map.merge(open_operation(), overrides)])

    :ok
  end

  defp mint_credit_for_guest(conn) do
    assert [_, _, %{"status" => "applied"}] =
             run_batch(conn, [
               open_operation(
                 operation_id: "op-open-src",
                 group_id: "group-src",
                 arrival_on: "2027-01-15",
                 departure_on: "2027-01-16",
                 rooms: [%{"room_id" => "room-x", "nightly_rate_cents" => 50_000}]
               ),
               payment_operation("op-pay-src", 10_000) |> Map.put("group_id", "group-src"),
               %{
                 "operation_id" => "op-cancel-src",
                 "type" => "cancel_group",
                 "occurred_on" => "2026-11-16",
                 "group_id" => "group-src",
                 "refund_method" => "hotel_credit"
               }
             ])

    :ok
  end

  defp run_batch(conn, operations) do
    conn |> submit_batch(operations) |> json_response(200) |> Map.fetch!("results")
  end

  defp group_json(conn) do
    %{"data" => group} = conn |> get_group("group-81") |> json_response(200)
    group
  end

  defp ledger_json(conn) do
    %{"data" => data} = conn |> get_ledger() |> json_response(200)
    data
  end

  defp get_report(conn, query) do
    Phoenix.ConnTest.dispatch(
      conn,
      GroupStayWeb.Endpoint,
      :get,
      "/api/v1/finance/daily-report" <> query,
      nil
    )
  end

  defp start_op(operation_id, starts_on) do
    %{
      "operation_id" => operation_id,
      "type" => "start_finance_reporting",
      "starts_on" => starts_on
    }
  end

  defp payment_operation(operation_id, amount_cents, occurred_on \\ "2026-10-05") do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => occurred_on,
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(operation_id, source_group_id, destination_group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "occurred_on" => occurred_on,
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
  end

  defp reduce_op(operation_id, target_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => target_id,
      "amount_cents" => amount_cents
    }
  end

  defp charge_back_op(operation_id, target_id, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => occurred_on,
      "payment_operation_id" => target_id
    }
  end

  defp apply_credit_op(operation_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end
end
