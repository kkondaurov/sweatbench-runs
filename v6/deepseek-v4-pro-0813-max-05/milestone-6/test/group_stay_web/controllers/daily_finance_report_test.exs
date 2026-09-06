defmodule GroupStayWeb.DailyFinanceReportTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  defp start_reporting(overrides \\ %{}) do
    %{
      "operation_id" => "op-start",
      "type" => "start_finance_reporting",
      "starts_on" => "2026-10-01"
    }
    |> Map.merge(overrides)
  end

  defp report_path(date), do: "/api/v1/finance/daily-report?date=#{date}"

  defp daily_report(conn, date) do
    json_response(get(conn, report_path(date)), 200)["data"]
  end

  defp cash_movements(overrides \\ %{}) do
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
    |> Map.merge(overrides)
  end

  defp credit_movements(overrides \\ %{}) do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
    |> Map.merge(overrides)
  end

  defp ams_cash(overrides) do
    %{
      "property_id" => "ams-canal",
      "opening_held_cents" => 0,
      "movements" => cash_movements(),
      "closing_held_cents" => 0
    }
    |> Map.merge(overrides)
  end

  defp credit(overrides \\ %{}) do
    %{
      "opening_liability_cents" => 0,
      "movements" => credit_movements(),
      "closing_liability_cents" => 0
    }
    |> Map.merge(overrides)
  end

  describe "starting finance reporting" do
    test "applies the first start operation and snapshots the opening position", %{conn: conn} do
      open_group!(conn)
      json_post(conn, payment(%{"occurred_on" => "2026-11-01", "amount_cents" => 10_000}))

      conn = json_post(conn, start_reporting())

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-start",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 }
               ]
             }

      # The already-committed payment is part of the opening position even
      # though its occurred_on is after starts_on.
      assert daily_report(conn, "2026-10-01") == %{
               "date" => "2026-10-01",
               "status" => "open",
               "cash" => [
                 ams_cash(%{
                   "opening_held_cents" => 10_000,
                   "closing_held_cents" => 10_000
                 })
               ],
               "credit" => credit()
             }
    end

    test "operations earlier in the same batch open the position and later ones move", %{
      conn: conn
    } do
      conn =
        submit(conn, [
          open_group(%{"operation_id" => "open-81"}),
          payment(%{
            "operation_id" => "pay-early",
            "occurred_on" => "2026-11-01",
            "amount_cents" => 10_000
          }),
          start_reporting(%{"operation_id" => "op-start"}),
          payment(%{
            "operation_id" => "pay-late",
            "occurred_on" => "2026-12-01",
            "amount_cents" => 5_000
          })
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied", "applied"]

      # On starts_on only the opening position exists; the late payment
      # posts on its own occurred_on.
      assert daily_report(conn, "2026-10-01") == %{
               "date" => "2026-10-01",
               "status" => "open",
               "cash" => [
                 ams_cash(%{"opening_held_cents" => 10_000, "closing_held_cents" => 10_000})
               ],
               "credit" => credit()
             }

      assert daily_report(conn, "2026-12-01")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 15_000
               })
             ]

      assert daily_report(conn, "2026-12-01")["credit"] == credit()
    end

    test "a different start operation is rejected and retries replay exactly", %{conn: conn} do
      json_post(conn, start_reporting())

      rebooter = start_reporting(%{"operation_id" => "op-start-2", "starts_on" => "2027-01-01"})

      conn = json_post(conn, rebooter)

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-start-2",
                   "status" => "rejected",
                   "code" => "reporting_already_started"
                 }
               ]
             }

      # The rejection is durable and replays without touching domain state.
      [rejection] = json_response(conn, 200)["results"]
      assert json_response(json_post(conn, rebooter), 200) == %{"results" => [rejection]}

      # The original start still replays as applied.
      conn = json_post(conn, start_reporting())

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-start",
                   "status" => "applied",
                   "starts_on" => "2026-10-01"
                 }
               ]
             }

      # Reusing the original identifier with a different payload conflicts.
      assert [
               %{
                 "operation_id" => "op-start",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ] =
               json_response(
                 json_post(conn, start_reporting(%{"starts_on" => "2026-10-02"})),
                 200
               )["results"]
    end

    test "an invalid or missing starts_on is invalid_reporting_date and starts nothing", %{
      conn: conn
    } do
      for {index, bad} <- Enum.with_index([nil, "nope", "2026-13-40", "2026-10-1", 123]) do
        operation_id = "op-bad-#{index}"
        op = start_reporting(%{"operation_id" => operation_id})

        op =
          if bad == nil do
            Map.delete(op, "starts_on")
          else
            %{op | "starts_on" => bad}
          end

        assert [
                 %{
                   "operation_id" => ^operation_id,
                   "status" => "rejected",
                   "code" => "invalid_reporting_date"
                 }
               ] = json_response(json_post(conn, op), 200)["results"]
      end

      assert json_response(get(conn, report_path("2026-10-05")), 404) == %{
               "error" => %{"code" => "report_not_available"}
             }
    end

    test "an operation without a type-derived group works with no revision guard", %{conn: conn} do
      op =
        start_reporting(%{"operation_id" => "op-start", "starts_on" => "2026-10-01"})
        |> Map.put("occurred_on", "2026-08-20")
        |> Map.put("expected_revision", 3)

      assert [%{"status" => "applied", "starts_on" => "2026-10-01"}] =
               json_response(json_post(conn, op), 200)["results"]
    end
  end

  describe "reading one day" do
    test "missing or invalid dates are 422 and unavailable reports are 404", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/finance/daily-report"), 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert json_response(get(conn, "/api/v1/finance/daily-report?date=nope"), 422) == %{
               "error" => %{"code" => "invalid_reporting_date"}
             }

      assert json_response(get(conn, report_path("2026-10-05")), 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      json_post(conn, start_reporting())

      assert json_response(get(conn, report_path("2026-09-30")), 404) == %{
               "error" => %{"code" => "report_not_available"}
             }

      assert json_response(get(conn, report_path("2026-10-01")), 200)["data"]["date"] ==
               "2026-10-01"
    end

    test "an operation processed after starting posts on the later of occurred_on and starts_on",
         %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      # Later occurrence posts on occurred_on.
      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-late",
          "occurred_on" => "2026-11-05",
          "amount_cents" => 5_000
        })
      )

      assert daily_report(conn, "2026-11-05")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 5_000
               })
             ]

      # Earlier occurrence is clamped to starts_on.
      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-early",
          "occurred_on" => "2026-08-15",
          "amount_cents" => 5_000
        })
      )

      assert daily_report(conn, "2026-10-01")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 5_000
               })
             ]

      # The day before starts_on stays unavailable even with movement present.
      assert json_response(get(conn, report_path("2026-08-15")), 404)["error"]["code"] ==
               "report_not_available"
    end

    test "later submissions change an earlier open report", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      assert daily_report(conn, "2026-11-01")["cash"] == []

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 5_000
        })
      )

      assert daily_report(conn, "2026-11-01")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 5_000
               })
             ]
    end

    test "reading reports never changes any report or domain state", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 5_000
        })
      )

      ledger_before = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      group_before = json_response(get(conn, groups_path("group-81")), 200)["data"]

      first = daily_report(conn, "2026-11-01")
      second = daily_report(conn, "2026-11-01")
      assert first == second

      # Reading in any order is equally side-effect free.
      _ = daily_report(conn, "2026-12-25")
      _ = daily_report(conn, "2026-10-01")

      assert json_response(get(conn, "/api/v1/ledger"), 200)["data"] == ledger_before
      assert json_response(get(conn, groups_path("group-81")), 200)["data"] == group_before
    end
  end

  describe "cash movements" do
    test "payments received, refunded, retained, and converted settle per property", %{conn: conn} do
      json_post(conn, start_reporting())

      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 10_000
        })
      )

      # Refundable cash cancellation.
      json_post(conn, cancel(%{"operation_id" => "cancel-1", "occurred_on" => "2026-11-20"}))

      assert daily_report(conn, "2026-11-20")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "movements" => cash_movements(%{"refunded_cents" => 10_000}),
                 "closing_held_cents" => 0
               })
             ]

      # A non-refundable group retains instead.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-adv",
          "group_id" => "group-adv",
          "rate_plan" => "advance_purchase"
        })
      ])

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-adv",
          "group_id" => "group-adv",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 5_000
        })
      )

      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-adv",
          "group_id" => "group-adv",
          "occurred_on" => "2026-11-21"
        })
      )

      assert daily_report(conn, "2026-11-21")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 5_000,
                 "movements" => cash_movements(%{"retained_cents" => 5_000}),
                 "closing_held_cents" => 0
               })
             ]

      # Hotel-credit conversion is a cash movement plus issued liability.
      submit(conn, [
        open_group(%{"operation_id" => "open-cv", "group_id" => "group-cv"})
      ])

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-cv",
          "group_id" => "group-cv",
          "occurred_on" => "2026-11-03",
          "amount_cents" => 10_000
        })
      )

      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-cv",
          "group_id" => "group-cv",
          "occurred_on" => "2026-11-22",
          "refund_method" => "hotel_credit"
        })
      )

      report = daily_report(conn, "2026-11-22")

      assert report["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "movements" => cash_movements(%{"converted_to_credit_cents" => 10_000}),
                 "closing_held_cents" => 0
               })
             ]

      assert report["credit"] ==
               credit(%{
                 "movements" => credit_movements(%{"issued_cents" => 11_000}),
                 "closing_liability_cents" => 11_000
               })
    end

    test "reductions, chargebacks, and transfers reconcile against opening held", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 10_000
        })
      )

      json_post(
        conn,
        reduce_cash(%{
          "operation_id" => "reduce-1",
          "payment_operation_id" => "pay-1",
          "occurred_on" => "2026-11-10",
          "amount_cents" => 1_000
        })
      )

      assert daily_report(conn, "2026-11-10")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "movements" => cash_movements(%{"reduced_cents" => 1_000}),
                 "closing_held_cents" => 9_000
               })
             ]

      # A chargeback after a refund moves the refunded classification and
      # reports the reversal as negative refunded plus charged-back cash.
      json_post(conn, cancel(%{"operation_id" => "cancel-1", "occurred_on" => "2026-11-20"}))

      json_post(
        conn,
        charge_back(%{
          "operation_id" => "charge-1",
          "payment_operation_id" => "pay-1",
          "occurred_on" => "2026-11-25"
        })
      )

      assert daily_report(conn, "2026-11-25")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 0,
                 "movements" =>
                   cash_movements(%{"refunded_cents" => -9_000, "charged_back_cents" => 9_000}),
                 "closing_held_cents" => 0
               })
             ]
    end

    test "transfers report out at the source property and in at the destination", %{conn: conn} do
      json_post(conn, start_reporting())

      open_group!(conn)

      submit(conn, [
        open_group(%{
          "operation_id" => "open-92",
          "group_id" => "group-92",
          "guest_id" => "guest-22",
          "property_id" => "utr-central"
        })
      ])

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 10_000
        })
      )

      json_post(
        conn,
        transfer_deposit(%{
          "operation_id" => "move-1",
          "destination_group_id" => "group-92",
          "occurred_on" => "2026-11-12",
          "amount_cents" => 2_000
        })
      )

      assert daily_report(conn, "2026-11-12")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "movements" => cash_movements(%{"transferred_out_cents" => 2_000}),
                 "closing_held_cents" => 8_000
               }),
               %{
                 "property_id" => "utr-central",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"transferred_in_cents" => 2_000}),
                 "closing_held_cents" => 2_000
               }
             ]
    end

    test "all-zero properties are omitted and entries are ordered by property_id", %{conn: conn} do
      json_post(conn, start_reporting())

      submit(conn, [
        open_group(%{
          "operation_id" => "open-z",
          "group_id" => "group-z",
          "guest_id" => "guest-22",
          "property_id" => "zuid-arena"
        })
      ])

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-z",
          "group_id" => "group-z",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 3_000
        })
      )

      # ams-canal never held cash and has no movements, so it is omitted.
      assert daily_report(conn, "2026-11-01")["cash"] == [
               %{
                 "property_id" => "zuid-arena",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 3_000}),
                 "closing_held_cents" => 3_000
               }
             ]

      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-a",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 2_000
        })
      )

      cash = daily_report(conn, "2026-11-02")["cash"]
      assert Enum.map(cash, & &1["property_id"]) == ["ams-canal", "zuid-arena"]
      assert Enum.at(cash, 0)["movements"]["received_cents"] == 2_000
    end
  end

  describe "credit movements" do
    test "credit outstanding before reporting starts opens the liability position", %{conn: conn} do
      # The conversion and its lot exist before reporting starts.
      issue_lot(conn, "group-src", "cancel-src")

      json_post(conn, start_reporting(%{"starts_on" => "2026-11-21"}))

      assert daily_report(conn, "2026-11-21")["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "closing_liability_cents" => 11_000
               })

      # The lot still expires on the day after expires_on.
      assert daily_report(conn, "2027-11-22")["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "movements" => credit_movements(%{"expired_cents" => 11_000}),
                 "closing_liability_cents" => 0
               })
    end

    test "apply does not move liability and expiry reports with no operation", %{conn: conn} do
      json_post(conn, start_reporting())

      issue_lot(conn, "group-src", "cancel-src")

      # The issued liability posts on the conversion date.
      assert daily_report(conn, "2026-11-20")["credit"] ==
               credit(%{
                 "movements" => credit_movements(%{"issued_cents" => 11_000}),
                 "closing_liability_cents" => 11_000
               })

      # Applying part of the lot keeps liability unchanged and has no
      # movement column.
      open_group(conn, "group-tgt", %{"operation_id" => "open-tgt"})

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-1",
          "group_id" => "group-tgt",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 5_500
        })
      )

      assert daily_report(conn, "2026-11-25")["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "closing_liability_cents" => 11_000
               })

      # The unused 5_500 expires the day after expires_on, even with no
      # partner operation that day; the applied 5_500 stays liability.
      report = daily_report(conn, "2027-11-22")

      assert report["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "movements" => credit_movements(%{"expired_cents" => 5_500}),
                 "closing_liability_cents" => 5_500
               })

      # The report reconciles with the ledger as of that date: the applied
      # 5_500 is still liability, the unused remainder expired.
      assert json_response(get(conn, "/api/v1/ledger?on=2027-11-22"), 200)["data"][
               "credit_liability_cents"
             ] == 5_500
    end

    test "non-refundable settlement consumes applied credit", %{conn: conn} do
      json_post(conn, start_reporting())
      issue_lot(conn, "group-src", "cancel-src")

      submit(conn, [
        open_group(%{
          "operation_id" => "open-adv",
          "group_id" => "group-adv",
          "guest_id" => "guest-22",
          "rate_plan" => "advance_purchase"
        })
      ])

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-1",
          "group_id" => "group-adv",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 5_000
        })
      )

      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-adv",
          "group_id" => "group-adv",
          "occurred_on" => "2026-11-27"
        })
      )

      assert daily_report(conn, "2026-11-27")["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "movements" => credit_movements(%{"consumed_cents" => 5_000}),
                 "closing_liability_cents" => 6_000
               })

      assert json_response(get(conn, "/api/v1/ledger?on=2026-11-27"), 200)["data"][
               "credit_liability_cents"
             ] == 6_000
    end

    test "chargebacks revoke entitlement and restoration absorbs the shortfall", %{conn: conn} do
      json_post(conn, start_reporting())
      issue_lot(conn, "group-src", "cancel-src")

      open_group(conn, "group-tgt", %{
        "operation_id" => "open-tgt",
        "arrival_on" => "2027-01-10",
        "departure_on" => "2027-01-13"
      })

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-1",
          "group_id" => "group-tgt",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 5_500
        })
      )

      # Chargeback of the converted payment revokes the entitlement still in
      # the lot; the spent 5_500 becomes a shortfall, not a movement.
      json_post(
        conn,
        charge_back(%{
          "operation_id" => "charge-1",
          "payment_operation_id" => "pay-group-src",
          "occurred_on" => "2026-11-26"
        })
      )

      report = daily_report(conn, "2026-11-26")

      assert report["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "movements" => credit_movements(%{"revoked_cents" => 5_500}),
                 "closing_liability_cents" => 5_500
               })

      # Refundable cash cancellation of the funded group restores the spent
      # credit; the shortfall absorbs the whole restoration.
      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-tgt",
          "group_id" => "group-tgt",
          "occurred_on" => "2026-11-27"
        })
      )

      assert daily_report(conn, "2026-11-27")["credit"] ==
               credit(%{
                 "opening_liability_cents" => 5_500,
                 "movements" => credit_movements(%{"absorbed_cents" => 5_500}),
                 "closing_liability_cents" => 0
               })

      ledger = json_response(get(conn, "/api/v1/ledger?on=2026-11-27"), 200)["data"]
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end

    test "restoring credit whose expiry has passed reports expiry immediately", %{conn: conn} do
      json_post(conn, start_reporting())
      issue_lot(conn, "group-src", "cancel-src")

      open_group(conn, "group-tgt", %{
        "operation_id" => "open-tgt",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      json_post(
        conn,
        apply_credit(%{
          "operation_id" => "apply-1",
          "group_id" => "group-tgt",
          "occurred_on" => "2026-11-25",
          "amount_cents" => 5_000
        })
      )

      # Cancellation after the lot's expiry (2027-11-21) cannot restore it;
      # the spent amount reports as expired on the cancellation date.
      json_post(
        conn,
        cancel(%{
          "operation_id" => "cancel-tgt",
          "group_id" => "group-tgt",
          "occurred_on" => "2027-11-22"
        })
      )

      report = daily_report(conn, "2027-11-22")

      assert report["credit"] ==
               credit(%{
                 "opening_liability_cents" => 11_000,
                 "movements" => credit_movements(%{"expired_cents" => 11_000}),
                 "closing_liability_cents" => 0
               })

      assert json_response(get(conn, "/api/v1/ledger?on=2027-11-22"), 200)["data"][
               "credit_liability_cents"
             ] == 0
    end
  end

  describe "movement integrity" do
    test "a rejected later operation in a batch keeps earlier movements", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      conn =
        submit(conn, [
          payment(%{
            "operation_id" => "good",
            "occurred_on" => "2026-11-01",
            "amount_cents" => 10_000
          }),
          payment(%{
            "operation_id" => "bad",
            "occurred_on" => "2026-11-01",
            "amount_cents" => 20_000
          })
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.map(results, & &1["status"]) == ["applied", "rejected"]
      assert Enum.at(results, 1)["code"] == "payment_exceeds_outstanding"

      assert daily_report(conn, "2026-11-01")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 10_000}),
                 "closing_held_cents" => 10_000
               })
             ]
    end

    test "reports reconcile with the current ledger views", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-1",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 10_000
        })
      )

      json_post(
        conn,
        reduce_cash(%{
          "operation_id" => "reduce-1",
          "payment_operation_id" => "pay-1",
          "occurred_on" => "2026-11-05",
          "amount_cents" => 1_000
        })
      )

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-2",
          "occurred_on" => "2026-11-06",
          "amount_cents" => 5_000
        })
      )

      json_post(conn, cancel(%{"operation_id" => "cancel-1", "occurred_on" => "2026-11-20"}))

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 14_000
      assert ledger["cash_reduced_cents"] == 1_000

      # Each movement classification lands on its own day.
      assert daily_report(conn, "2026-11-01")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 10_000}),
                 "closing_held_cents" => 10_000
               })
             ]

      assert daily_report(conn, "2026-11-05")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "movements" => cash_movements(%{"reduced_cents" => 1_000}),
                 "closing_held_cents" => 9_000
               })
             ]

      assert daily_report(conn, "2026-11-06")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 9_000,
                 "movements" => cash_movements(%{"received_cents" => 5_000}),
                 "closing_held_cents" => 14_000
               })
             ]

      assert daily_report(conn, "2026-11-20")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 14_000,
                 "movements" => cash_movements(%{"refunded_cents" => 14_000}),
                 "closing_held_cents" => 0
               })
             ]

      # A later report's closing position equals the current ledger; days
      # with neither opening, closing, nor movements show no cash entry.
      final = daily_report(conn, "2026-12-01")
      assert final["cash"] == []

      assert final["credit"]["closing_liability_cents"] ==
               json_response(get(conn, "/api/v1/ledger"), 200)["data"]["credit_liability_cents"]
    end

    test "rejected operations leave no movement and retries never double-report", %{conn: conn} do
      json_post(conn, start_reporting())
      open_group!(conn)

      # Rejection: the payment exceeds the outstanding deposit.
      overdue =
        payment(%{
          "operation_id" => "pay-bad",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 25_000
        })

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               json_response(json_post(conn, overdue), 200)["results"]

      assert daily_report(conn, "2026-11-01")["cash"] == []

      good =
        payment(%{
          "operation_id" => "pay-good",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 10_000
        })

      assert [%{"status" => "applied"}] = json_response(json_post(conn, good), 200)["results"]

      # Retrying the applied payment replays its stored result without a
      # second received movement.
      assert [%{"status" => "applied"}] = json_response(json_post(conn, good), 200)["results"]

      assert daily_report(conn, "2026-11-02")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 10_000}),
                 "closing_held_cents" => 10_000
               })
             ]

      # Retrying the rejection adds nothing either.
      assert [%{"status" => "rejected"}] = json_response(json_post(conn, overdue), 200)["results"]
      assert daily_report(conn, "2026-11-01")["cash"] == []
    end

    test "one combined batch builds the same movements as sequential submissions", %{conn: conn} do
      # Sequential world: open, two payments, one on each day.
      json_post(conn, start_reporting())
      open_group!(conn)

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-a",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 6_000
        })
      )

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-b",
          "occurred_on" => "2026-11-02",
          "amount_cents" => 4_000
        })
      )

      assert daily_report(conn, "2026-11-01")["cash"] == [
               ams_cash(%{
                 "movements" => cash_movements(%{"received_cents" => 6_000}),
                 "closing_held_cents" => 6_000
               })
             ]

      assert daily_report(conn, "2026-11-02")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 6_000,
                 "movements" => cash_movements(%{"received_cents" => 4_000}),
                 "closing_held_cents" => 10_000
               })
             ]

      # Batched world: the same operations as one batch on another group.
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-batch",
            "group_id" => "group-batch",
            "guest_id" => "guest-batch",
            "property_id" => "utr-central"
          }),
          payment(%{
            "operation_id" => "pay-c",
            "group_id" => "group-batch",
            "occurred_on" => "2026-11-03",
            "amount_cents" => 6_000
          })
        ])

      assert Enum.map(json_response(conn, 200)["results"], & &1["status"]) == [
               "applied",
               "applied"
             ]

      assert daily_report(conn, "2026-11-03")["cash"] == [
               ams_cash(%{
                 "opening_held_cents" => 10_000,
                 "closing_held_cents" => 10_000
               }),
               %{
                 "property_id" => "utr-central",
                 "opening_held_cents" => 0,
                 "movements" => cash_movements(%{"received_cents" => 6_000}),
                 "closing_held_cents" => 6_000
               }
             ]
    end
  end

  # Opens a group for the guest, pays 10_000, and cancels it with hotel
  # credit so the guest owns an 11_000 lot expiring 2027-11-21.
  defp issue_lot(conn, group_id, cancel_operation_id) do
    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-#{group_id}",
          "group_id" => group_id,
          "guest_id" => "guest-22"
        }),
        payment(%{
          "operation_id" => "pay-#{group_id}",
          "group_id" => group_id,
          "occurred_on" => "2026-11-01",
          "amount_cents" => 10_000
        }),
        cancel(%{
          "operation_id" => cancel_operation_id,
          "group_id" => group_id,
          "occurred_on" => "2026-11-20",
          "refund_method" => "hotel_credit"
        })
      ])

    results = json_response(conn, 200)["results"]
    assert Enum.map(results, & &1["status"]) == ["applied", "applied", "applied"]
    conn
  end

  # Opens a flexible group for the same guest.
  defp open_group(conn, group_id, overrides) do
    submit(conn, [
      open_group(
        %{
          "operation_id" => "open-#{group_id}",
          "group_id" => group_id,
          "guest_id" => "guest-22"
        }
        |> Map.merge(overrides)
      )
    ])
  end
end
