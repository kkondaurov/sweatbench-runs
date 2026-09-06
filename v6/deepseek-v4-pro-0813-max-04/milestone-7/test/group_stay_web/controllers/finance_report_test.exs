defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase, async: false

  import GroupStay.Operations

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp batch_results(conn, operations),
    do: json_response(post_batch(conn, operations), 200)["results"]

  defp get_report(conn, date), do: get(conn, "/api/v1/finance/daily-report", %{"date" => date})

  defp report(conn, date), do: json_response(get_report(conn, date), 200)["data"]

  defp report_error(conn, date) do
    response = get_report(conn, date)
    {response.status, json_response(response, response.status)}
  end

  defp ledger(conn, params \\ %{}),
    do: json_response(get(conn, "/api/v1/ledger", params), 200)["data"]

  defp cash_of(report, property_id),
    do: Enum.find(report["cash"], &(&1["property_id"] == property_id))

  defp movements_of(entry), do: entry["movements"]

  defp open_other(overrides \\ %{}) do
    Map.merge(
      open(%{
        "operation_id" => "op-open-92",
        "group_id" => "group-92",
        "property_id" => "bcn-plaza"
      }),
      overrides
    )
  end

  defp issue_credit(conn, overrides \\ %{}) do
    source =
      open(%{
        "operation_id" => "op-source",
        "group_id" => "group-source",
        "guest_id" => "guest-22",
        "arrival_on" => "2027-06-01",
        "departure_on" => "2027-06-04"
      })

    pay =
      payment(%{
        "operation_id" => "op-pay-source",
        "group_id" => "group-source",
        "amount_cents" => 4_000
      })

    credit_cancel =
      Map.merge(
        cancel(%{
          "operation_id" => "op-cancel-source",
          "group_id" => "group-source",
          "occurred_on" => "2026-10-15",
          "refund_method" => "hotel_credit"
        }),
        overrides
      )

    batch_results(conn, [source, pay, credit_cancel])
  end

  describe "starting finance reporting" do
    test "returns exactly operation_id, status, and starts_on" do
      conn = build_conn()

      assert batch_results(conn, [start_finance_reporting()]) == [
               %{
                 "operation_id" => "op-start-reporting",
                 "status" => "applied",
                 "starts_on" => "2026-10-15"
               }
             ]
    end

    test "rejects a different start operation once reporting has started" do
      conn = build_conn()

      other =
        start_finance_reporting(%{
          "operation_id" => "op-start-later",
          "starts_on" => "2026-11-01"
        })

      results =
        batch_results(conn, [
          start_finance_reporting(),
          other
        ])

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-start-later",
               "status" => "rejected",
               "code" => "reporting_already_started"
             }

      # The rejected attempt changes nothing.
      assert report(conn, "2026-10-15")["date"] == "2026-10-15"
      assert report_error(conn, "2026-10-14") |> elem(0) == 404
    end

    test "rejects invalid or missing starts_on with invalid_reporting_date" do
      conn = build_conn()

      invalid = start_finance_reporting(%{"starts_on" => "not-a-date"})

      missing =
        Map.delete(start_finance_reporting(%{"operation_id" => "op-no-starts-on"}), "starts_on")

      results = batch_results(conn, [invalid, missing])

      assert Enum.at(results, 0) == %{
               "operation_id" => "op-start-reporting",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      assert Enum.at(results, 1) == %{
               "operation_id" => "op-no-starts-on",
               "status" => "rejected",
               "code" => "invalid_reporting_date"
             }

      # Nothing started: reports stay unavailable and a later valid start works.
      assert report_error(conn, "2026-10-15") |> elem(0) == 404

      valid = start_finance_reporting(%{"operation_id" => "op-start-valid"})

      assert batch_results(conn, [valid]) |> hd() |> Map.get("status") == "applied"
    end

    test "retries replay the stored result and different payloads conflict" do
      conn = build_conn()

      start = start_finance_reporting()

      assert batch_results(conn, [start]) == batch_results(conn, [start])

      conflict =
        start_finance_reporting(%{"starts_on" => "2026-10-16"})

      assert batch_results(conn, [conflict]) == [
               %{
                 "operation_id" => "op-start-reporting",
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
             ]
    end
  end

  describe "reading one day" do
    test "returns 422 invalid_reporting_date for missing or invalid dates" do
      conn = build_conn()
      batch_results(conn, [start_finance_reporting()])

      missing = get(conn, "/api/v1/finance/daily-report")
      assert missing.status == 422
      assert json_response(missing, 422) == %{"error" => %{"code" => "invalid_reporting_date"}}

      assert report_error(conn, "2026-13-40") ==
               {422, %{"error" => %{"code" => "invalid_reporting_date"}}}

      assert report_error(conn, "tomorrow") ==
               {422, %{"error" => %{"code" => "invalid_reporting_date"}}}
    end

    test "returns 404 report_not_available before reporting started" do
      conn = build_conn()

      assert report_error(conn, "2026-10-15") ==
               {404, %{"error" => %{"code" => "report_not_available"}}}
    end

    test "returns 404 report_not_available before starts_on" do
      conn = build_conn()
      batch_results(conn, [start_finance_reporting()])

      assert report_error(conn, "2026-10-14") ==
               {404, %{"error" => %{"code" => "report_not_available"}}}

      assert report(conn, "2026-10-15")["status"] == "open"
    end
  end

  describe "opening position" do
    test "operations committed before the start fold into the opening position" do
      conn = build_conn()

      # The payment's occurred_on is after starts_on, but it is processed
      # before the start operation, so it belongs to the opening position.
      early_payment = payment(%{"occurred_on" => "2026-10-16", "amount_cents" => 4_000})

      batch_results(conn, [open(), early_payment, start_finance_reporting()])

      day = report(conn, "2026-10-15")
      ams = cash_of(day, "ams-canal")

      assert ams == %{
               "property_id" => "ams-canal",
               "opening_held_cents" => 4_000,
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
               "closing_held_cents" => 4_000
             }

      assert report(conn, "2026-10-16")["cash"] == day["cash"]
    end

    test "operations after the start in the same batch contribute movements" do
      conn = build_conn()

      late_payment = payment(%{"occurred_on" => "2026-10-16", "amount_cents" => 4_000})

      batch_results(conn, [open(), start_finance_reporting(), late_payment])

      starting_day = report(conn, "2026-10-15")
      next_day = report(conn, "2026-10-16")

      assert starting_day["cash"] == []

      ams_next = cash_of(next_day, "ams-canal")
      assert movements_of(ams_next)["received_cents"] == 4_000
      assert ams_next["opening_held_cents"] == 0
      assert ams_next["closing_held_cents"] == 4_000
    end
  end

  describe "cash movements" do
    test "reports received, refunded, and the charged-back reversal" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000}),
        cancel(%{"occurred_on" => "2026-10-20"}),
        charge_back(%{"occurred_on" => "2026-10-21"})
      ])

      payment_day = cash_of(report(conn, "2026-10-20"), "ams-canal")
      assert movements_of(payment_day)["received_cents"] == 4_000
      assert movements_of(payment_day)["refunded_cents"] == 4_000
      assert payment_day["closing_held_cents"] == 0

      reversal_day = cash_of(report(conn, "2026-10-21"), "ams-canal")
      assert movements_of(reversal_day)["refunded_cents"] == -4_000
      assert movements_of(reversal_day)["charged_back_cents"] == 4_000
      assert reversal_day["closing_held_cents"] == 0
    end

    test "reports retained cash on a non-refundable cancellation" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000}),
        cancel(%{"occurred_on" => "2026-12-05"})
      ])

      day = cash_of(report(conn, "2026-12-05"), "ams-canal")
      assert movements_of(day)["retained_cents"] == 4_000
      assert day["closing_held_cents"] == 0
    end

    test "reports converted cash and a reduction" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{
          "operation_id" => "op-pay-a",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 4_000
        }),
        payment(%{
          "operation_id" => "op-pay-b",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 3_000
        }),
        reduce(%{
          "operation_id" => "op-reduce-b",
          "payment_operation_id" => "op-pay-b",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 1_000
        }),
        cancel(%{"occurred_on" => "2026-10-21", "refund_method" => "hotel_credit"})
      ])

      day = cash_of(report(conn, "2026-10-20"), "ams-canal")
      assert movements_of(day)["received_cents"] == 7_000
      assert movements_of(day)["reduced_cents"] == 1_000
      assert day["closing_held_cents"] == 6_000

      convert_day = cash_of(report(conn, "2026-10-21"), "ams-canal")
      assert movements_of(convert_day)["converted_to_credit_cents"] == 6_000
      assert convert_day["closing_held_cents"] == 0
    end

    test "orders cash by property_id and omits all-zero properties" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        open_other(),
        open(%{
          "operation_id" => "op-open-empty",
          "group_id" => "group-empty",
          "property_id" => "zzz-empty"
        }),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000}),
        payment(%{
          "operation_id" => "op-pay-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 2_000
        })
      ])

      day = report(conn, "2026-10-20")

      assert Enum.map(day["cash"], & &1["property_id"]) == ["ams-canal", "bcn-plaza"]
      refute Enum.any?(day["cash"], &(&1["property_id"] == "zzz-empty"))
    end

    test "transfers report equal amounts across properties and follow the cash" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        open_other(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000}),
        transfer(%{"occurred_on" => "2026-10-21", "amount_cents" => 2_000}),
        cancel(%{
          "operation_id" => "op-cancel-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-22"
        })
      ])

      transfer_day = report(conn, "2026-10-21")

      ams = cash_of(transfer_day, "ams-canal")
      bcn = cash_of(transfer_day, "bcn-plaza")

      assert movements_of(ams)["transferred_out_cents"] == 2_000
      assert ams["closing_held_cents"] == 2_000
      assert movements_of(bcn)["transferred_in_cents"] == 2_000
      assert bcn["closing_held_cents"] == 2_000

      transferred_in =
        transfer_day["cash"]
        |> Enum.map(fn entry -> movements_of(entry)["transferred_in_cents"] end)
        |> Enum.sum()

      transferred_out =
        transfer_day["cash"]
        |> Enum.map(fn entry -> movements_of(entry)["transferred_out_cents"] end)
        |> Enum.sum()

      assert transferred_in == transferred_out

      # Settlement lands where the cash is held, not at the payment's
      # original property.
      settle_day = report(conn, "2026-10-22")
      assert movements_of(cash_of(settle_day, "ams-canal"))["refunded_cents"] == 0
      assert movements_of(cash_of(settle_day, "bcn-plaza"))["refunded_cents"] == 2_000
      assert cash_of(settle_day, "bcn-plaza")["closing_held_cents"] == 0
    end

    test "backdated operations post on starts_on" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-10", "amount_cents" => 4_000})
      ])

      day = report(conn, "2026-10-15")
      assert movements_of(cash_of(day, "ams-canal"))["received_cents"] == 4_000
    end

    test "rejected operations leave no movement and retries move nothing twice" do
      conn = build_conn()

      over =
        payment(%{
          "operation_id" => "op-over",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 19_501
        })

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000}),
        over
      ])

      day = report(conn, "2026-10-20")
      assert movements_of(cash_of(day, "ams-canal"))["received_cents"] == 4_000

      # A durable retry of the applied payment must not double the movement.
      batch_results(conn, [payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000})])

      assert report(conn, "2026-10-20")["cash"] == day["cash"]
    end
  end

  describe "credit movements" do
    test "reports issuance, expiry without operations, and the closing chain" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-15", "amount_cents" => 4_000}),
        cancel(%{"occurred_on" => "2026-10-15", "refund_method" => "hotel_credit"})
      ])

      # 4_000 cash converts into a 4_400 lot available through 2027-10-16
      # and expiring on 2027-10-17.
      issue_day = report(conn, "2026-10-15")["credit"]

      assert issue_day == %{
               "opening_liability_cents" => 0,
               "movements" => %{
                 "issued_cents" => 4_400,
                 "expired_cents" => 0,
                 "consumed_cents" => 0,
                 "revoked_cents" => 0,
                 "absorbed_cents" => 0
               },
               "closing_liability_cents" => 4_400
             }

      alive_day = report(conn, "2027-10-16")["credit"]
      assert alive_day["movements"]["expired_cents"] == 0
      assert alive_day["closing_liability_cents"] == 4_400

      expiry_day = report(conn, "2027-10-17")["credit"]
      assert expiry_day["movements"]["expired_cents"] == 4_400
      assert expiry_day["closing_liability_cents"] == 0

      later = report(conn, "2027-10-18")["credit"]
      assert later["movements"]["expired_cents"] == 0
      assert later["closing_liability_cents"] == 0
    end

    test "only the unspent remainder expires while credit stays applied" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-15", "amount_cents" => 4_000}),
        cancel(%{"occurred_on" => "2026-10-15", "refund_method" => "hotel_credit"}),
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        }),
        apply_credit(%{
          "group_id" => "group-target",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 2_000
        })
      ])

      # 2_000 of the 4_400 lot funds the target when the expiry date passes;
      # only the 2_400 unspent remainder expires.
      expiry_day = report(conn, "2027-10-17")["credit"]
      assert expiry_day["movements"]["expired_cents"] == 2_400
      assert expiry_day["closing_liability_cents"] == 2_000

      after_day = report(conn, "2027-10-18")["credit"]
      assert after_day["opening_liability_cents"] == 2_000
      assert after_day["closing_liability_cents"] == 2_000
    end

    test "reports consumed credit on non-refundable settlement" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"amount_cents" => 19_500})
      ])

      issue_credit(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22"
        })

      batch_results(conn, [
        target,
        apply_credit(%{
          "group_id" => "group-target",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 4_000
        }),
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2026-12-05"
        })
      ])

      day = report(conn, "2026-12-05")["credit"]
      assert day["movements"]["consumed_cents"] == 4_000
      assert day["opening_liability_cents"] == 4_400
      assert day["closing_liability_cents"] == 400
    end

    test "reports revocation and absorption" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"amount_cents" => 19_500})
      ])

      issue_credit(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-04"
        })

      batch_results(conn, [
        target,
        apply_credit(%{
          "group_id" => "group-target",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 2_000
        }),
        charge_back(%{"payment_operation_id" => "op-pay-source", "occurred_on" => "2027-03-01"})
      ])

      # 4_400 entitlement with 2_400 remaining: 2_400 revoked, 2_000 becomes
      # unrecovered clawback.
      revoke_day = report(conn, "2027-03-01")["credit"]
      assert revoke_day["movements"]["revoked_cents"] == 2_400
      assert revoke_day["opening_liability_cents"] == 4_400
      assert revoke_day["closing_liability_cents"] == 2_000

      batch_results(conn, [
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2027-02-01"
        })
      ])

      # The restoration extinguishes the clawback instead of becoming
      # available credit again; after the revocation day nothing remains.
      absorb_day = report(conn, "2027-02-01")["credit"]
      assert absorb_day["movements"]["absorbed_cents"] == 2_000
      assert absorb_day["opening_liability_cents"] == 4_400
      assert absorb_day["closing_liability_cents"] == 2_400

      assert report(conn, "2027-03-02")["credit"]["closing_liability_cents"] == 0
    end

    test "revoking credit after its expiry leaves the expiry movement intact" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"amount_cents" => 19_500})
      ])

      issue_credit(conn)

      # The lot expires on 2027-10-17; the chargeback arrives a month later,
      # when the liability has already left through expiry.
      batch_results(conn, [
        charge_back(%{"payment_operation_id" => "op-pay-source", "occurred_on" => "2027-11-01"})
      ])

      revoke_day = report(conn, "2027-11-01")["credit"]
      assert revoke_day["movements"]["revoked_cents"] == 0
      assert revoke_day["opening_liability_cents"] == 0
      assert revoke_day["closing_liability_cents"] == 0

      assert report(conn, "2027-10-17")["credit"]["movements"]["expired_cents"] == 4_400
    end

    test "restored credit on an expired lot expires immediately on that day" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"amount_cents" => 19_500})
      ])

      # The 4_400 lot is available through 2027-10-16 and expires 2027-10-17.
      issue_credit(conn)

      target =
        open(%{
          "operation_id" => "op-target",
          "group_id" => "group-target",
          "guest_id" => "guest-22",
          "arrival_on" => "2028-03-01",
          "departure_on" => "2028-03-04"
        })

      batch_results(conn, [
        target,
        apply_credit(%{
          "group_id" => "group-target",
          "occurred_on" => "2026-11-01",
          "amount_cents" => 2_000
        }),
        cancel(%{
          "operation_id" => "op-cancel-target",
          "group_id" => "group-target",
          "occurred_on" => "2028-02-16"
        })
      ])

      # The lot expired long before the cancellation, so the 2_000
      # restoration expires immediately on the cancellation's posting date.
      restore_day = report(conn, "2028-02-16")["credit"]
      assert restore_day["movements"]["expired_cents"] == 2_000
      assert restore_day["opening_liability_cents"] == 2_000
      assert restore_day["closing_liability_cents"] == 0

      # The natural expiry of the unspent 2_400 happened on 2027-10-17.
      assert report(conn, "2027-10-17")["credit"]["movements"]["expired_cents"] == 2_400
    end
  end

  describe "report integrity" do
    test "a later backdated submission changes an earlier open report" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000})
      ])

      assert report(conn, "2026-10-18")["cash"] == []

      # A payment that occurred on 10-18 arrives after the 10-20 payment and
      # posts on 10-18, changing that earlier day's report.
      batch_results(conn, [
        payment(%{
          "operation_id" => "op-pay-18",
          "occurred_on" => "2026-10-18",
          "amount_cents" => 1_000
        })
      ])

      day18 = cash_of(report(conn, "2026-10-18"), "ams-canal")
      assert movements_of(day18)["received_cents"] == 1_000
      assert day18["opening_held_cents"] == 0
      assert day18["closing_held_cents"] == 1_000

      # The 10-19 report still chains correctly between the two days.
      day19 = cash_of(report(conn, "2026-10-19"), "ams-canal")
      assert day19["opening_held_cents"] == 1_000
      assert day19["closing_held_cents"] == 1_000

      day20 = cash_of(report(conn, "2026-10-20"), "ams-canal")
      assert movements_of(day20)["received_cents"] == 4_000
      assert day20["opening_held_cents"] == 1_000
      assert day20["closing_held_cents"] == 5_000
    end

    test "equivalent batches and sequential submissions produce equivalent reports" do
      conn = build_conn()
      open_a = open()
      pay_a = payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000})

      pay_b =
        payment(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 2_000
        })

      cancel_a = cancel(%{"occurred_on" => "2026-10-21"})

      batch_results(conn, [start_finance_reporting(), open_a, pay_a, pay_b, cancel_a])
      batched = report(conn, "2026-10-22")

      conn2 = build_conn()
      batch_results(conn2, [start_finance_reporting(), open_a])
      batch_results(conn2, [pay_a])
      batch_results(conn2, [pay_b, cancel_a])

      assert report(conn2, "2026-10-22") == batched
    end

    test "reading reports never changes state and repeats are identical" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000})
      ])

      before = ledger(conn)
      first = report(conn, "2026-10-20")

      assert report(conn, "2026-10-15")["status"] == "open"
      assert report(conn, "2026-10-20") == first
      assert report(conn, "2027-10-17")["credit"]["movements"]["expired_cents"] == 0
      assert report(conn, "2026-10-20") == first
      assert ledger(conn) == before
    end

    test "movements reconcile to the current views" do
      conn = build_conn()

      batch_results(conn, [
        start_finance_reporting(),
        open(),
        open_other(),
        payment(%{"occurred_on" => "2026-10-20", "amount_cents" => 4_000}),
        payment(%{
          "operation_id" => "op-pay-92",
          "group_id" => "group-92",
          "occurred_on" => "2026-10-20",
          "amount_cents" => 2_000
        }),
        transfer(%{"occurred_on" => "2026-10-21", "amount_cents" => 1_500}),
        cancel(%{"occurred_on" => "2026-10-22", "refund_method" => "hotel_credit"})
      ])

      day = report(conn, "2026-10-22")
      current = ledger(conn, %{"on" => "2026-10-22"})

      held =
        day["cash"]
        |> Enum.map(& &1["closing_held_cents"])
        |> Enum.sum()

      assert held == current["cash_held_cents"]
      assert day["credit"]["closing_liability_cents"] == current["credit_liability_cents"]

      # The per-day chain also rolls correctly into a later quiet day.
      later = report(conn, "2026-10-23")
      assert Enum.map(later["cash"], & &1["closing_held_cents"]) |> Enum.sum() == held
      assert later["credit"]["closing_liability_cents"] == current["credit_liability_cents"]
    end
  end
end
